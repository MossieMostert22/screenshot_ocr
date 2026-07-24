package com.mossiemostert22.screenshot_ocr

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.database.ContentObserver
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.provider.MediaStore
import androidx.core.app.NotificationCompat
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The always-on heart of the app. This foreground service OWNS the entire
 * detection-and-OCR pipeline, completely independent of the Flutter UI:
 *
 *   1. Watches MediaStore for new/changed screenshot rows (ContentObserver).
 *   2. Applies the size-version barrier + IS_PENDING guard so Samsung scroll
 *      captures produce exactly ONE final result.
 *   3. Runs ML Kit text recognition natively (no Flutter engine required).
 *   4. Applies the replacement filter (same-path rule + fuzzy token overlap),
 *      writes history into FlutterSharedPreferences as a JSON string, copies
 *      to clipboard, and fires exactly one notification tone per task.
 *   5. Broadcasts ACTION_NEW_OCR so an open UI can refresh instantly.
 *
 * Because everything lives here, swiping the app away no longer kills
 * screenshot tracking: the activity is just a viewer.
 */
class ScreenshotWatcherService : Service() {

    companion object {
        const val ACTION_NEW_OCR = "com.mossiemostert22.screenshot_ocr.NEW_OCR"

        const val SERVICE_NOTIFICATION_ID = 7001
        const val TASK_NOTIFICATION_ID = 5001

        const val SERVICE_CHANNEL_ID = "ocr_service_survival_channel"
        const val SOUND_CHANNEL_ID = "ocr_sound_tray_chan_v9"
        const val SILENT_CHANNEL_ID = "ocr_silent_tray_chan_v9"

        // Flutter's shared_preferences plugin stores everything in this file,
        // with every key prefixed "flutter." — we read/write the same store.
        const val PREFS_FILE = "FlutterSharedPreferences"
        const val KEY_HISTORY = "flutter.ocr_history_json"
        const val KEY_SOUND = "flutter.ocr_sound_enabled"
        const val KEY_AUTOCOPY = "flutter.ocr_auto_copy"

        // Raised from 50 so gallery imports (potentially 100+ screenshots)
        // aren't trimmed away by the next live capture.
        const val MAX_HISTORY = 200
    }

    private var screenshotObserver: ContentObserver? = null
    private val processedMediaVersions = HashMap<Long, Long>()
    private var recognizer: TextRecognizer? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannels()
        promoteToForeground()
        recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
        registerScreenshotObserver()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // If Android kills us under memory pressure, restart automatically.
        return START_STICKY
    }

    override fun onDestroy() {
        screenshotObserver?.let { contentResolver.unregisterContentObserver(it) }
        screenshotObserver = null
        recognizer?.close()
        recognizer = null
        super.onDestroy()
    }

    // ------------------------------------------------------------------
    // Foreground plumbing
    // ------------------------------------------------------------------

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        manager.createNotificationChannel(
            NotificationChannel(
                SERVICE_CHANNEL_ID,
                "Background Service Survival Monitor",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps screenshot tracking alive when the app is closed."
                setShowBadge(false)
            }
        )
        manager.createNotificationChannel(
            NotificationChannel(
                SOUND_CHANNEL_ID,
                "Audible Task Tray Notifications",
                NotificationManager.IMPORTANCE_HIGH
            ).apply { description = "Fires text extraction indicators with sound" }
        )
        manager.createNotificationChannel(
            NotificationChannel(
                SILENT_CHANNEL_ID,
                "Silent Task Tray Notifications",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Fires text extraction indicators silently"
                setSound(null, null)
                enableVibration(false)
            }
        )
    }

    private fun promoteToForeground() {
        val notification = buildServiceNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                SERVICE_NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else {
            startForeground(SERVICE_NOTIFICATION_ID, notification)
        }
    }

    private fun buildServiceNotification(): Notification {
        return NotificationCompat.Builder(this, SERVICE_CHANNEL_ID)
            .setContentTitle("Screenshot OCR Tracking Active")
            .setContentText("Watching for new screenshots, even when the app is closed.")
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .setContentIntent(buildOpenAppIntent())
            .build()
    }

    private fun buildOpenAppIntent(): PendingIntent {
        val tapIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        return PendingIntent.getActivity(
            this, 0, tapIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    // ------------------------------------------------------------------
    // Screenshot detection (size-version barrier + IS_PENDING guard)
    // ------------------------------------------------------------------

    private data class ScreenshotState(
        val filePath: String,
        val isPending: Boolean,
        val fileSize: Long
    )

    private fun registerScreenshotObserver() {
        screenshotObserver = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean, uri: Uri?) {
                super.onChange(selfChange, uri)
                if (uri == null) return

                try {
                    val currentId = ContentUris.parseId(uri)
                    val state = queryScreenshotState(currentId) ?: return

                    // Samsung still writing the scroll capture — final signal comes later.
                    if (state.isPending || state.fileSize <= 0L) return

                    // Same content already processed → duplicate signal, drop it.
                    // Changed content (final stitched image) → process again.
                    if (processedMediaVersions[currentId] == state.fileSize) return
                    processedMediaVersions[currentId] = state.fileSize

                    if (processedMediaVersions.size > 200) {
                        processedMediaVersions.clear()
                        processedMediaVersions[currentId] = state.fileSize
                    }

                    val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
                    val wakeLock = powerManager.newWakeLock(
                        PowerManager.PARTIAL_WAKE_LOCK, "ScreenshotOCR::WakeLock"
                    )
                    wakeLock.acquire(6000)

                    Handler(Looper.getMainLooper()).postDelayed({
                        runOcrOnScreenshot(state.filePath)
                    }, 800)
                } catch (_: Exception) {}
            }
        }

        contentResolver.registerContentObserver(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true, screenshotObserver!!
        )
    }

    private fun queryScreenshotState(targetId: Long): ScreenshotState? {
        val projection = mutableListOf(
            MediaStore.Images.Media._ID,
            MediaStore.Images.Media.DISPLAY_NAME,
            MediaStore.Images.Media.RELATIVE_PATH,
            MediaStore.Images.Media.SIZE
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            projection.add(MediaStore.Images.Media.IS_PENDING)
        }

        val cursor: Cursor? = contentResolver.query(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            projection.toTypedArray(),
            "${MediaStore.Images.Media._ID} = ?",
            arrayOf(targetId.toString()),
            null
        )

        cursor?.use {
            if (it.moveToFirst()) {
                val fileName = it.getString(it.getColumnIndexOrThrow(MediaStore.Images.Media.DISPLAY_NAME)) ?: return null
                val relPath = it.getString(it.getColumnIndexOrThrow(MediaStore.Images.Media.RELATIVE_PATH)) ?: ""
                val size = it.getLong(it.getColumnIndexOrThrow(MediaStore.Images.Media.SIZE))
                val pending = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    it.getInt(it.getColumnIndexOrThrow(MediaStore.Images.Media.IS_PENDING)) == 1
                } else {
                    false
                }

                if (fileName.contains("Screenshot", ignoreCase = true) ||
                    relPath.contains("Screenshot", ignoreCase = true)
                ) {
                    val rootDir = getExternalFilesDir(null)?.parentFile?.parentFile?.parentFile?.parentFile
                    val fullPath = File(rootDir, "$relPath$fileName").absolutePath
                    return ScreenshotState(fullPath, pending, size)
                }
            }
        }
        return null
    }

    // ------------------------------------------------------------------
    // Native ML Kit OCR
    // ------------------------------------------------------------------

    private fun runOcrOnScreenshot(path: String) {
        val engine = recognizer ?: return
        try {
            val inputImage = InputImage.fromFilePath(this, Uri.fromFile(File(path)))
            engine.process(inputImage)
                .addOnSuccessListener { visionText ->
                    val cleanText = visionText.text
                        .replace("\n", " ")
                        .replace(Regex("\\s+"), " ")
                        .trim()
                    if (cleanText.isNotEmpty()) {
                        handleOcrResult(cleanText, path)
                    }
                }
                .addOnFailureListener { /* silent: nothing useful to show the user */ }
        } catch (_: Exception) {}
    }

    // ------------------------------------------------------------------
    // History, clipboard, notification — the same rules the Dart side used
    // ------------------------------------------------------------------

    @Suppress("ApplySharedPref")
    private fun handleOcrResult(cleanText: String, path: String) {
        try {
            val prefs = getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
            val soundEnabled = prefs.getBoolean(KEY_SOUND, true)
            val autoCopyEnabled = prefs.getBoolean(KEY_AUTOCOPY, true)

            val history = JSONArray(prefs.getString(KEY_HISTORY, "[]") ?: "[]")

            var isReplacement = false
            val kept = JSONArray()
            for (i in 0 until history.length()) {
                val entry = history.optJSONObject(i) ?: continue
                val existingText = entry.optString("text", "")
                val oldImagePath = entry.optString("image_path", "")

                // RULE 1 (bulletproof): same file → the final scroll image replaces
                // the first-frame card. RULE 2 (fuzzy): OCR noise differs between
                // passes, so use token overlap instead of exact substrings.
                val samePath = oldImagePath.isNotEmpty() && oldImagePath == path
                val expanded = !samePath && existingText.isNotEmpty() &&
                    isExpandedVersionOf(cleanText, existingText)

                if (samePath || expanded) {
                    isReplacement = true
                    // drop this entry (do not add to kept)
                } else {
                    kept.put(entry)
                }
            }

            if (autoCopyEnabled) {
                copyToClipboard(cleanText)
            }

            val newEntry = JSONObject().apply {
                put("text", cleanText)
                put(
                    "timestamp",
                    SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US).format(Date())
                )
                put("image_path", path)
            }

            val updated = JSONArray()
            updated.put(newEntry)
            for (i in 0 until kept.length()) {
                if (updated.length() >= MAX_HISTORY) break
                updated.put(kept.get(i))
            }

            // commit() (not apply): the Flutter side may reload immediately after
            // our broadcast, so the write must already be on disk.
            prefs.edit().putString(KEY_HISTORY, updated.toString()).commit()

            // Replacements update the tray silently: the user already got exactly
            // one completion tone when the first frame was processed.
            showTaskNotification(cleanText, soundEnabled && !isReplacement)

            // Wake the UI if it's open.
            sendBroadcast(Intent(ACTION_NEW_OCR).setPackage(packageName))
        } catch (_: Exception) {}
    }

    private fun copyToClipboard(text: String) {
        try {
            val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            clipboard.setPrimaryClip(ClipData.newPlainText("Extracted Text", text))
        } catch (_: Exception) {}
    }

    private fun showTaskNotification(snippetText: String, withSound: Boolean) {
        val channelId = if (withSound) SOUND_CHANNEL_ID else SILENT_CHANNEL_ID
        val displaySnippet =
            if (snippetText.length > 45) "${snippetText.substring(0, 45)}..." else snippetText

        val notification = NotificationCompat.Builder(this, channelId)
            .setContentTitle("📩 NEW TEXT EXTRACTED!")
            .setContentText(displaySnippet)
            .setStyle(NotificationCompat.BigTextStyle().bigText(displaySnippet))
            .setSmallIcon(applicationInfo.icon)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(buildOpenAppIntent())
            .build()

        try {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(TASK_NOTIFICATION_ID, notification)
        } catch (_: Exception) {}
    }

    // ------------------------------------------------------------------
    // Fuzzy comparison helpers (port of the Dart versions)
    // ------------------------------------------------------------------

    private fun normalizeForCompare(s: String): String {
        return s.lowercase(Locale.US)
            .replace(Regex("[^a-z0-9 ]"), " ")
            .replace(Regex("\\s+"), " ")
            .trim()
    }

    private fun isExpandedVersionOf(newText: String, oldText: String): Boolean {
        if (newText.length < oldText.length) return false
        val newTokens = normalizeForCompare(newText).split(" ").toHashSet()
        val oldTokens = normalizeForCompare(oldText).split(" ").filter { it.length > 2 }
        if (oldTokens.isEmpty()) return false
        val hits = oldTokens.count { newTokens.contains(it) }
        return hits.toDouble() / oldTokens.size >= 0.8
    }
}
