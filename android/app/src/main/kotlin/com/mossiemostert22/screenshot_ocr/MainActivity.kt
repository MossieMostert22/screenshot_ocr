package com.mossiemostert22.screenshot_ocr

import android.app.Activity
import android.app.PendingIntent
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.database.ContentObserver
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "screenshot_channel"
    private var screenshotObserver: ContentObserver? = null
    private var pendingDeletePath: String? = null
    private var deleteResultCallback: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        companionChannel = channel

        // Handle incoming deletion requests coming back from Flutter Dart side
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
                Handler(Looper.getMainLooper()).postDelayed({
                    val filePath = getLatestScreenshotPath(applicationContext)
                    if (filePath != null) {
                        forwardScreenshotToFlutter(applicationContext, filePath)
                    }
                }, 800)
            }
        }

        contentResolver.registerContentObserver(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            true,
            screenshotObserver!!
        )
    }

    private fun getLatestScreenshotPath(context: Context): String? {
        val projection = arrayOf(MediaStore.Images.Media._ID, MediaStore.Images.Media.DATA)
        val cursor: Cursor? = context.contentResolver.query(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            projection,
            null,
            null,
            "${MediaStore.Images.Media.DATE_TAKEN} DESC"
        )

        cursor?.use {
            if (it.moveToFirst()) {
                val dataIndex = it.getColumnIndexOrThrow(MediaStore.Images.Media.DATA)
                val path = it.getString(dataIndex)
                if (path.contains("Screenshot", ignoreCase = true)) {
                    return path
                }
            }
        }
        return null
    }

    private fun executeSecureDelete(filePath: String) {
        try {
            val context = applicationContext
            val projection = arrayOf(MediaStore.Images.Media._ID)
            val cursor = context.contentResolver.query(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                projection,
                "${MediaStore.Images.Media.DATA} = ?",
                arrayOf(filePath),
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
                // Modern Android 11 to 16 native popup trigger
                val pendingIntent = MediaStore.createDeleteRequest(context.contentResolver, listOf(uri))
                startIntentSenderForResult(
                    pendingIntent.intentSender, 
                    1001, 
                    null, 
                    0, 
                    0, 
                    0
                )
            } else {
                // Legacy system fallback
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
            // Check if user clicked "Allow/Delete" inside the native Android popup system drawer
            if (resultCode == Activity.RESULT_OK) {
                deleteResultCallback?.success(true)
            } else {
                deleteResultCallback?.success(false)
            }
        }
    }

    override fun onDestroy() {
        screenshotObserver?.let {
            contentResolver.unregisterContentObserver(it)
        }
        companionChannel = null
        super.onDestroy()
    }

    companion object {
        @JvmStatic
        var companionChannel: MethodChannel? = null

        @JvmStatic
        fun forwardScreenshotToFlutter(context: Context, filePath: String) {
            val channel = companionChannel
            if (channel != null) {
                Handler(Looper.getMainLooper()).post {
                    channel.invokeMethod("onScreenshotTaken", filePath)
                }
            }
        }
    }
}
