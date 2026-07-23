import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:clipboard/clipboard.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class OcrService {
  static const MethodChannel _channel = MethodChannel('screenshot_channel');
  final TextRecognizer _textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();

  static const int _taskNotificationId = 5001;

  Function(String, String)? onOcrComplete;
  Function(String)? onOcrError;

  void initialize() async {
    _channel.setMethodCallHandler(_handleMethodCall);
    await _initNotifications();
  }

  Future<void> _initNotifications() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initializationSettings =
        InitializationSettings(android: initializationSettingsAndroid);

    // FIXED: Added the actual required 'settings:' keyword constraint for version 22+
    await _notificationsPlugin.initialize(
      settings: initializationSettings,
    );
  }

  Future<void> showSingleTaskNotification(String snippetText, bool isSoundActive) async {
    final AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      isSoundActive ? 'ocr_sound_tray_chan_v9' : 'ocr_silent_tray_chan_v9',
      isSoundActive ? 'Audible Task Tray Notifications' : 'Silent Task Tray Notifications',
      channelDescription: 'Fires text extraction indicators to status trays securely',
      importance: Importance.max,
      priority: Priority.high,
      playSound: isSoundActive,
      enableVibration: isSoundActive,
      showWhen: true,
      styleInformation: const BigTextStyleInformation(''),
    );

    final NotificationDetails platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);

    String displaySnippet = snippetText.length > 45 ? '${snippetText.substring(0, 45)}...' : snippetText;

    // ENFORCED: Modern version explicit named parameter mapping loops
    await _notificationsPlugin.show(
      id: _taskNotificationId,
      title: '📩 NEW TEXT EXTRACTED!',
      body: displaySnippet,
      notificationDetails: platformChannelSpecifics,
    );
  }

  Future<void> clearActiveNotificationTray() async {
    // ENFORCED: Modern version named parameter cancel execution
    await _notificationsPlugin.cancel(id: _taskNotificationId);
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method == "onScreenshotTaken") {
      final String? filePath = call.arguments as String?;
      if (filePath != null && filePath.isNotEmpty) {
        await processScreenshot(filePath);
      }
    }
  }

  Future<void> processScreenshot(String path) async {
    try {
      final inputImage = InputImage.fromFilePath(path);
      final RecognizedText recognizedText = await _textRecognizer.processImage(inputImage);

      String cleanText = _cleanupText(recognizedText.text);

      if (cleanText.trim().isEmpty) {
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      bool userSoundSetting = prefs.getBool('ocr_sound_enabled') ?? true;

      List<String> history = prefs.getStringList('ocr_history') ?? [];
      List<String> itemsToRemove = [];

      // Tracks whether this capture REPLACES an existing card (scroll-capture
      // final image landing on top of the already-processed first frame).
      bool isReplacement = false;

      for (String itemStr in history) {
        try {
          Map<String, dynamic> existingEntry = jsonDecode(itemStr);
          String existingText = existingEntry['text'] ?? '';
          String oldImagePath = existingEntry['image_path'] ?? '';

          // RULE 1 (bulletproof): the new capture is the SAME FILE as an existing
          // card. Samsung scroll captures overwrite the first frame's file with
          // the final stitched image, so the old card must be replaced. No text
          // comparison needed — the path match is exact.
          bool samePath = oldImagePath.isNotEmpty && oldImagePath == path;

          // RULE 2 (fuzzy fallback): OCR noise differs between passes, so exact
          // substring checks fail randomly. Instead require that ~80% of the old
          // card's words appear inside the new, longer text.
          bool expandedVersion = !samePath &&
              existingText.isNotEmpty &&
              _isExpandedVersionOf(cleanText, existingText);

          if (samePath || expandedVersion) {
            itemsToRemove.add(itemStr);
            isReplacement = true;
            if (expandedVersion && oldImagePath.isNotEmpty && oldImagePath != path) {
              await deleteScreenshotFile(oldImagePath);
            }
          }
        } catch (_) {}
      }

      history.removeWhere((element) => itemsToRemove.contains(element));

      await FlutterClipboard.copy(cleanText);

      history.insert(0, jsonEncode({
        'text': cleanText,
        'timestamp': DateTime.now().toIso8601String(),
        'image_path': path,
      }));

      if (history.length > 50) history = history.sublist(0, 50);
      await prefs.setStringList('ocr_history', history);

      // Replacements update the tray silently: the user already got exactly one
      // completion tone when the first frame was processed.
      await showSingleTaskNotification(cleanText, userSoundSetting && !isReplacement);

      if (onOcrComplete != null) {
        onOcrComplete!(cleanText, path);
      }
    } catch (e) {
      if (onOcrError != null) onOcrError!("Processing Block Failed: ${e.toString()}");
    }
  }

  Future<bool> deleteScreenshotFile(String path) async {
    try {
      final bool? success = await _channel.invokeMethod<bool>(
        'deleteGalleryFile',
        {'path': path},
      );
      return success ?? false;
    } catch (e) {
      return false;
    }
  }

  // Normalizes OCR output so two noisy passes over the same screen can be
  // compared: lowercase, strip punctuation/symbols, collapse whitespace.
  String _normalizeForCompare(String s) {
    return s
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  // True when newText is a longer capture that contains (almost all of) the
  // words of oldText — i.e. the completed scroll version of a partial frame.
  bool _isExpandedVersionOf(String newText, String oldText) {
    if (newText.length < oldText.length) return false;
    final Set<String> newTokens = _normalizeForCompare(newText).split(' ').toSet();
    final List<String> oldTokens = _normalizeForCompare(oldText)
        .split(' ')
        .where((t) => t.length > 2)
        .toList();
    if (oldTokens.isEmpty) return false;
    int hits = 0;
    for (final t in oldTokens) {
      if (newTokens.contains(t)) hits++;
    }
    return hits / oldTokens.length >= 0.8;
  }

  String _cleanupText(String rawText) {
    return rawText.replaceAll('\n', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  void dispose() {
    _textRecognizer.close();
  }
}