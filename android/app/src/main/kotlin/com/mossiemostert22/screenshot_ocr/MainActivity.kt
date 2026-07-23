package com.mossiemostert22.screenshot_ocr

import android.app.Activity
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * The activity is now a pure VIEWER. All screenshot detection and OCR moved
 * into ScreenshotWatcherService, which survives the app being swiped away.
 * The activity's remaining jobs: start the service, refresh the Flutter UI
 * when the service broadcasts a new result, and run the secure-delete flow
 * (which needs an activity for the system confirmation dialog).
 */
class MainActivity : FlutterActivity() {
    private val channelName = "screenshot_channel"
    private var deleteResultCallback: MethodChannel.Result? = null
    private var refreshReceiver: BroadcastReceiver? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Boot the always-on watcher. If it's already running this is a no-op.
        val serviceIntent = Intent(this, ScreenshotWatcherService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent)
        } else {
            startService(serviceIntent)
        }

        registerRefreshReceiver()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        companionChannel = channel

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "deleteGalleryFile" -> {
                    val filePath = call.argument<String>("path")
                    if (filePath != null) {
                        deleteResultCallback = result
                        executeSecureDelete(filePath)
                    } else {
                        result.success(false)
                    }
                }
                "clearTaskNotification" -> {
                    try {
                        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                        manager.cancel(ScreenshotWatcherService.TASK_NOTIFICATION_ID)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Refreshes the Flutter inbox instantly when the service finishes an OCR task. */
    private fun registerRefreshReceiver() {
        refreshReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                companionChannel?.invokeMethod("onHistoryChanged", null)
            }
        }
        val filter = IntentFilter(ScreenshotWatcherService.ACTION_NEW_OCR)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(refreshReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(refreshReceiver, filter)
        }
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
        refreshReceiver?.let { unregisterReceiver(it) }
        refreshReceiver = null
        companionChannel = null
        super.onDestroy()
    }

    companion object {
        @JvmStatic var companionChannel: MethodChannel? = null
    }
}
