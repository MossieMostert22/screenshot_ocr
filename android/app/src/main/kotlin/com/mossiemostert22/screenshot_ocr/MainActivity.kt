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

    // TARGETED ID BARRIER: Tracks specific media database row IDs instead of clock times
    private val processedMediaIds = HashSet<Long>()

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

    private fun registerScreenshotObserver() {
        screenshotObserver = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean, uri: Uri?) {
                super.onChange(selfChange, uri)
                if (uri == null) return

                try {
                    // Extract unique database entry row ID numbers from incoming notification payloads
                    val currentId = ContentUris.parseId(uri)
                    
                    // FIXED: Instantly drop duplicate signals if this exact image asset ID has been handled
                    if (processedMediaIds.contains(currentId)) return
                    processedMediaIds.add(currentId)

                    // Enforce cache cleanup bounds
                    if (processedMediaIds.size > 100) {
                        processedMediaIds.clear()
                    }

                    val powerManager = applicationContext.getSystemService(Context.POWER_SERVICE) as PowerManager
                    val wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "ScreenshotOCR::WakeLock")
                    wakeLock.acquire(4000)

                    Handler(Looper.getMainLooper()).postDelayed({
                        // FIXED: Scan recent files using non-deprecated metadata rules
                        val filePath = verifyAndGetRecentScreenshotPath(applicationContext, currentId)
                        if (filePath != null) {
                            forwardScreenshotToFlutter(applicationContext, filePath)
                        }
                    }, 800)
                } catch (_: Exception) {}
            }
        }

        contentResolver.registerContentObserver(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true, screenshotObserver!!)
    }

    private fun verifyAndGetRecentScreenshotPath(context: Context, targetId: Long): String? {
        // FIXED: Replaced deprecated DATA column references with current DISPLAY_NAME asset parameters
        val projection = arrayOf(MediaStore.Images.Media._ID, MediaStore.Images.Media.DISPLAY_NAME, MediaStore.Images.Media.RELATIVE_PATH)
        
        val cursor: Cursor? = context.contentResolver.query(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            projection,
            "${MediaStore.Images.Media._ID} = ?",
            arrayOf(targetId.toString()),
            null
        )

        cursor?.use {
            if (it.moveToFirst()) {
                val nameIndex = it.getColumnIndexOrThrow(MediaStore.Images.Media.DISPLAY_NAME)
                val pathIndex = it.getColumnIndexOrThrow(MediaStore.Images.Media.RELATIVE_PATH)
                val fileName = it.getString(nameIndex)
                val relPath = it.getString(pathIndex)

                // Match against screenshots directories cleanly without scoped tracking errors
                if (fileName.contains("Screenshot", ignoreCase = true) || relPath.contains("Screenshot", ignoreCase = true)) {
                    val rootDir = context.getExternalFilesDir(null)?.parentFile?.parentFile?.parentFile?.parentFile
                    return File(rootDir, "$relPath$fileName").absolutePath
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
