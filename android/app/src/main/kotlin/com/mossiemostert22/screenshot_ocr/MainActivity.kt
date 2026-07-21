package com.mossiemostert22.screenshot_ocr

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "screenshot_channel"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Correctly initialize and assign the messenger pipeline globally
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        companionChannel = channel
    }

    override fun onDestroy() {
        // Clean up memory reference contexts when the app context closes down
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
