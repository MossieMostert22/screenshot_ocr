package com.mossiemostert22.screenshot_ocr

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "screenshot_channel"

    private var methodChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        companionChannel = methodChannel
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
    }

    companion object {
        private var companionChannel: MethodChannel? = null

        fun forwardScreenshotToFlutter(context: Context, filePath: String) {
            val channel = companionChannel
            if (channel == null) {
                return
            }

            Handler(Looper.getMainLooper()).post {
                channel.invokeMethod("onScreenshotTaken", filePath)
            }
        }
    }
}
