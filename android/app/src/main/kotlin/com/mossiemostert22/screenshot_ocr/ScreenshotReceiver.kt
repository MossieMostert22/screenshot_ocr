package com.mossiemostert22.screenshot_ocr

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.provider.MediaStore
import android.os.Handler
import android.os.Looper

class ScreenshotReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        // Listen for standard intent action paths broadcasted by the OS
        if (intent.action == "android.intent.action.SCREENSHOT" || intent.action == "com.samsung.android.capture.SCREENSHOT_EVENT") {
            
            // Give the device gallery database half a second to finish saving the file to disk
            Handler(Looper.getMainLooper()).postDelayed({
                val filePath = getLatestScreenshotPath(context)
                if (filePath != null) {
                    MainActivity.forwardScreenshotToFlutter(context, filePath)
                }
            }, 750)
        }
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
}
