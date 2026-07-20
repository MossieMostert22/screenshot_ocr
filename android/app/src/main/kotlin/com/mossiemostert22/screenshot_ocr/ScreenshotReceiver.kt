package com.mossiemostert22.screenshot_ocr

import android.Manifest
import android.content.BroadcastReceiver
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.MediaStore
import androidx.core.content.ContextCompat

class ScreenshotReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val appContext = context.applicationContext
        val screenshotPath = when (intent?.action) {
            ACTION_SCREENSHOT -> intent.getStringExtra(EXTRA_FILE_PATH)
            else -> queryLatestScreenshotPath(appContext)
        }

        if (!screenshotPath.isNullOrBlank()) {
            MainActivity.forwardScreenshotToFlutter(appContext, screenshotPath)
        }
    }

    private fun queryLatestScreenshotPath(context: Context): String? {
        if (!hasRequiredImagePermission(context)) {
            return null
        }

        val projection = arrayOf(
            MediaStore.Images.Media._ID,
            MediaStore.Images.Media.DISPLAY_NAME,
            MediaStore.Images.Media.DATA,
        )
        val selection = "${MediaStore.Images.Media.DISPLAY_NAME} LIKE ?"
        val selectionArgs = arrayOf("%screenshot%")
        val sortOrder = "${MediaStore.Images.Media.DATE_ADDED} DESC"

        context.contentResolver.query(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            projection,
            selection,
            selectionArgs,
            sortOrder,
        )?.use { cursor ->
            val idColumn = cursor.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
            val displayNameColumn = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DISPLAY_NAME)
            val dataColumn = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATA)

            while (cursor.moveToNext()) {
                val displayName = cursor.getString(displayNameColumn).orEmpty()
                if (!displayName.contains("screenshot", ignoreCase = true)) {
                    continue
                }

                val dataPath = cursor.getString(dataColumn)
                if (!dataPath.isNullOrBlank()) {
                    return dataPath
                }

                val imageId = cursor.getLong(idColumn)
                return ContentUris.withAppendedId(
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                    imageId,
                ).toString()
            }
        }

        return null
    }

    private fun hasRequiredImagePermission(context: Context): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.READ_MEDIA_IMAGES,
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.READ_EXTERNAL_STORAGE,
            ) == PackageManager.PERMISSION_GRANTED
        }
    }

    companion object {
        const val ACTION_SCREENSHOT = "android.intent.action.SCREENSHOT"
        const val EXTRA_FILE_PATH = "file_path"
    }
}
