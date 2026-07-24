package com.mossiemostert22.screenshot_ocr

import android.content.Context
import android.graphics.BitmapFactory
import android.graphics.BitmapRegionDecoder
import android.graphics.Rect
import android.net.Uri
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognizer
import java.io.File

/**
 * ML Kit silently downscales very tall images (long scroll captures) to fit
 * its internal limits, shrinking the text into unreadable specks — the OCR
 * then returns garbage like a single letter. This helper slices tall images
 * into full-resolution horizontal segments, recognizes each one, and stitches
 * the text back together.
 *
 * All functions MUST be called off the main thread (they block on ML Kit).
 */
object TiledTextOcr {

    /** Images taller than this are processed in segments. */
    private const val MAX_SEGMENT_HEIGHT = 2400

    fun recognize(context: Context, recognizer: TextRecognizer, path: String): String? {
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            val width = bounds.outWidth
            val height = bounds.outHeight
            if (width <= 0 || height <= 0) return null

            if (height <= MAX_SEGMENT_HEIGHT) {
                // Normal-sized image: single pass, straight from file.
                val image = InputImage.fromFilePath(context, Uri.fromFile(File(path)))
                return Tasks.await(recognizer.process(image)).text
            }

            // Tall image: decode and recognize region by region at full resolution.
            @Suppress("DEPRECATION")
            val decoder = BitmapRegionDecoder.newInstance(path, false) ?: return null
            val stitched = StringBuilder()
            try {
                var y = 0
                while (y < height) {
                    val segmentHeight = minOf(MAX_SEGMENT_HEIGHT, height - y)
                    val region = Rect(0, y, width, y + segmentHeight)
                    val bitmap = decoder.decodeRegion(region, null) ?: break
                    try {
                        val image = InputImage.fromBitmap(bitmap, 0)
                        val text = Tasks.await(recognizer.process(image)).text
                        if (text.isNotBlank()) {
                            stitched.append(text).append('\n')
                        }
                    } finally {
                        bitmap.recycle()
                    }
                    y += segmentHeight
                }
            } finally {
                decoder.recycle()
            }
            stitched.toString()
        } catch (e: Exception) {
            null
        }
    }
}
