package com.mossiemostert22.screenshot_ocr

import android.content.Context
import android.database.ContentObserver
import android.database.Cursor
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "screenshot_channel"
    private var screenshotObserver: ContentObserver? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        companionChannel = channel

        // Start listening to the MediaStore gallery database directly
        registerScreenshotObserver()
    }

    private fun registerScreenshotObserver() {
        screenshotObserver = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean, uri: Uri?) {
                super.onChange(selfChange, uri)
                // Add a brief delay to allow Samsung to finish writing the file to disk
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
        val projection = arrayOf(MediaStore.Images.Media.DATA, MediaStore.Images.Media.DATE_TAKEN)
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
