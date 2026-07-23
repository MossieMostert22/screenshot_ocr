package com.mossiemostert22.screenshot_ocr

import android.app.Activity
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * The activity is a pure VIEWER plus the user-interaction endpoints that
 * genuinely need an Activity: the secure-delete confirmation flow and the
 * PDF save/open/share/delete handlers for the Saved Files feature.
 * All screenshot detection and OCR lives in ScreenshotWatcherService.
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
                "savePdfToDocuments" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    val fileName = call.argument<String>("fileName")
                    if (bytes == null || fileName.isNullOrBlank()) {
                        result.success(null)
                    } else {
                        result.success(savePdfToDocuments(bytes, fileName))
                    }
                }
                "openSavedPdf" -> result.success(openSavedPdf(call.argument<String>("uri")))
                "shareSavedPdf" -> result.success(shareSavedPdf(call.argument<String>("uri")))
                "deleteSavedPdf" -> result.success(deleteSavedPdf(call.argument<String>("uri")))
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

    // ------------------------------------------------------------------
    // Saved Files: MediaStore-based PDF persistence (no MANAGE_EXTERNAL_STORAGE)
    // ------------------------------------------------------------------

    /**
     * Writes the PDF into the public Documents/Screenshot OCR folder through
     * MediaStore. On Android 10+ this needs NO storage permission at all —
     * apps may always create their own documents. Returns the content URI
     * string on success (used later to open/share/delete the file).
     */
    private fun savePdfToDocuments(bytes: ByteArray, rawName: String): String? {
        return try {
            val name = if (rawName.endsWith(".pdf", ignoreCase = true)) rawName else "$rawName.pdf"
            val resolver = applicationContext.contentResolver
            val collection = MediaStore.Files.getContentUri("external")

            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, "application/pdf")
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    put(MediaStore.MediaColumns.RELATIVE_PATH, "Documents/Screenshot OCR")
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                } else {
                    @Suppress("DEPRECATION")
                    val dir = File(
                        Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS),
                        "Screenshot OCR"
                    )
                    if (!dir.exists()) dir.mkdirs()
                    @Suppress("DEPRECATION")
                    put(MediaStore.MediaColumns.DATA, File(dir, name).absolutePath)
                }
            }

            val uri = resolver.insert(collection, values) ?: return null
            resolver.openOutputStream(uri)?.use { it.write(bytes) } ?: return null

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val done = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
                resolver.update(uri, done, null, null)
            }
            uri.toString()
        } catch (e: Exception) {
            null
        }
    }

    /** Hands the PDF to whatever viewer the user has installed. */
    private fun openSavedPdf(uriStr: String?): Boolean {
        if (uriStr.isNullOrBlank()) return false
        return try {
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(Uri.parse(uriStr), "application/pdf")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    /** Opens the system share sheet (WhatsApp, email, etc.) with the PDF attached. */
    private fun shareSavedPdf(uriStr: String?): Boolean {
        if (uriStr.isNullOrBlank()) return false
        return try {
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "application/pdf"
                putExtra(Intent.EXTRA_STREAM, Uri.parse(uriStr))
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(intent, "Share PDF"))
            true
        } catch (e: Exception) {
            false
        }
    }

    /** Deletes a PDF this app created. As the owner, no system prompt is needed. */
    private fun deleteSavedPdf(uriStr: String?): Boolean {
        if (uriStr.isNullOrBlank()) return false
        return try {
            applicationContext.contentResolver.delete(Uri.parse(uriStr), null, null) > 0
        } catch (e: Exception) {
            false
        }
    }

    // ------------------------------------------------------------------
    // Secure delete of screenshot files (unchanged)
    // ------------------------------------------------------------------

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
