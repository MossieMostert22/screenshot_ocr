package com.mossiemostert22.screenshot_ocr

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "screenshot_channel"
    private var screenshotObserver: ContentObserver? = null
    private var deleteResultCallback: MethodChannel.Result? = null

    // VERSION BARRIER: Tracks each media row ID together with the file SIZE we last processed.
    // A scroll capture reuses the SAME row ID for the first frame and the final stitched image,
    // so we must re-process an ID whenever its underlying file content (size) changes.
    private val processedMediaVersions = HashMap<Long, Long>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            if (checkSelfPermission(Manifest.permission.FOREGROUND_SERVICE_SPECIAL_USE) != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(arrayOf(Manifest.permission.FOREGROUND_SERVICE_SPECIAL_USE), 1002)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        companionChannel = channel

        channel.setMethodCallHandler { call, result ->
            if (call.method == "deleteGalleryFile") {
                val filePath = call.argument<String>("path")
                if (filePath != null) {
                    deleteResultCallback = result
                    executeSecureDelete(filePath)
                } else {
                    result.success(false)
                }
            } else {
                result.notImplemented()
            }
        }

        registerScreenshotObserver()
    }

    // Holds the verified state of a screenshot row at the moment the observer fired
    private data class ScreenshotState(
        val filePath: String,
        val isPending: Boolean,
        val fileSize: Long
    )

    private fun registerScreenshotObserver() {
        screenshotObserver = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean, uri: Uri?) {
                super.onChange(selfChange, uri)
                if (uri == null) return

                try {
                    // Item-level URIs carry the media row ID; collection-level signals throw and are ignored
                    val currentId = ContentUris.parseId(uri)

                    val state = queryScreenshotState(applicationContext, currentId) ?: return

                    // Samsung marks the row as "pending" while a scroll capture is still being
                    // written. Skip it silently: a final onChange fires when the file is complete.
                    if (state.isPending || state.fileSize <= 0L) return

                    // Drop exact duplicate signals for content we already processed (prevents
                    // notification/beep storms), but let CHANGED content through so the final
                    // stitched scroll image replaces the first-frame text in the inbox.
                    if (processedMediaVersions[currentId] == state.fileSize) return
                    processedMediaVersions[currentId] = state.fileSize

                    // Enforce cache cleanup bounds
                    if (processedMediaVersions.size > 200) {
                        processedMediaVersions.clear()
                        processedMediaVersions[currentId] = state.fileSize
                    }

                    val powerManager = applicationContext.getSystemService(Context.POWER_SERVICE) as PowerManager
                    val wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "ScreenshotOCR::WakeLock")
                    wakeLock.acquire(4000)

                    Handler(Looper.getMainLooper()).postDelayed({
                        forwardScreenshotToFlutter(applicationContext, state.filePath)
                    }, 800)
                } catch (_: Exception) {}
            }
        }

        contentResolver.registerContentObserver(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true, screenshotObserver!!)
    }

    private fun queryScreenshotState(context: Context, targetId: Long): ScreenshotState? {
        val projection = mutableListOf(
            MediaStore.Images.Media._ID,
            MediaStore.Images.Media.DISPLAY_NAME,
            MediaStore.Images.Media.RELATIVE_PATH,
            MediaStore.Images.Media.SIZE
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            projection.add(MediaStore.Images.Media.IS_PENDING)
        }

        val cursor: Cursor? = context.contentResolver.query(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            projection.toTypedArray(),
            "${MediaStore.Images.Media._ID} = ?",
            arrayOf(targetId.toString()),
            null
        )

        cursor?.use {
            if (it.moveToFirst()) {
                val fileName = it.getString(it.getColumnIndexOrThrow(MediaStore.Images.Media.DISPLAY_NAME)) ?: return null
                val relPath = it.getString(it.getColumnIndexOrThrow(MediaStore.Images.Media.RELATIVE_PATH)) ?: ""
                val size = it.getLong(it.getColumnIndexOrThrow(MediaStore.Images.Media.SIZE))
                val pending = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    it.getInt(it.getColumnIndexOrThrow(MediaStore.Images.Media.IS_PENDING)) == 1
                } else {
                    false
                }

                // Only react to files living in a Screenshots location
                if (fileName.contains("Screenshot", ignoreCase = true) || relPath.contains("Screenshot", ignoreCase = true)) {
                    val rootDir = context.getExternalFilesDir(null)?.parentFile?.parentFile?.parentFile?.parentFile
                    val fullPath = File(rootDir, "$relPath$fileName").absolutePath
                    return ScreenshotState(fullPath, pending, size)
                }
            }
        }
        return null
    }

    private fun executeSecureDelete(filePath: String) {
        try {
            val context = applicationContext
            val file = File(filePath)
            val projection = arrayOf(MediaStore.Images.Media._ID)

            val cursor = context.contentResolver.query(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                projection,
                "${MediaStore.Images.Media.DISPLAY_NAME} = ?",
                arrayOf(file.name),
                null
            )

            var mediaId: Long = -1
            cursor?.use {
                if (it.moveToFirst()) {
                    mediaId = it.getLong(it.getColumnIndexOrThrow(MediaStore.Images.Media._ID))
                }
            }

            if (mediaId == -1L) {
                deleteResultCallback?.success(false)
                return
            }

            val uri = ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, mediaId)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val pendingIntent = MediaStore.createDeleteRequest(context.contentResolver, listOf(uri))
                startIntentSenderForResult(pendingIntent.intentSender, 1001, null, 0, 0, 0)
            } else {
                val deleted = context.contentResolver.delete(uri, null, null)
                deleteResultCallback?.success(deleted > 0)
            }
        } catch (e: Exception) {
            deleteResultCallback?.success(false)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 1001) {
            if (resultCode == Activity.RESULT_OK) {
                deleteResultCallback?.success(true)
            } else {
                deleteResultCallback?.success(false)
            }
        }
    }

    override fun onDestroy() {
        screenshotObserver?.let { contentResolver.unregisterContentObserver(it) }
        companionChannel = null
        super.onDestroy()
    }

    companion object {
        @JvmStatic var companionChannel: MethodChannel? = null
        @JvmStatic fun forwardScreenshotToFlutter(context: Context, filePath: String) {
            companionChannel?.let { channel ->
                Handler(Looper.getMainLooper()).post { channel.invokeMethod("onScreenshotTaken", filePath) }
            }
        }
    }
}