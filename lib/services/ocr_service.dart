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
  
  Function(String, String)? onOcrComplete;
  Function(String)? onOcrError;

  // SMART FLAG: Allows the main interface to dynamically silence individual slice captures
  bool isStitchingModeActive = false;

  void initialize() async {
    _channel.setMethodCallHandler(_handleMethodCall);
    await _initNotifications();
  }

  Future<void> _initNotifications() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initializationSettings =
        InitializationSettings(android: initializationSettingsAndroid);
    await _notificationsPlugin.initialize(settings: initializationSettings);
  }

  Future<void> showStandoutNotification(String snippetText, {required bool forceSilence}) async {
    final AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      forceSilence ? 'screenshot_ocr_silent_channel_v2' : 'screenshot_ocr_alert_channel_v2',
      forceSilence ? 'Silent Snippet Processing' : 'Screenshot OCR Completion Alerts',
      channelDescription: 'Manages sound pollution loops during multi-page capture sequences',
      importance: forceSilence ? Importance.low : Importance.max,
      priority: forceSilence ? Priority.low : Priority.high,
      playSound: !forceSilence, // CRITICAL FIX: Explicitly kills the audio beep track
      enableVibration: !forceSilence,
      showWhen: true,
      styleInformation: const BigTextStyleInformation(''),
    );
    
    final NotificationDetails platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);
    
    String displaySnippet = snippetText.length > 40 ? '${snippetText.substring(0, 40)}...' : snippetText;

    await _notificationsPlugin.show(
      id: forceSilence ? 1 : 0,
      title: forceSilence ? '📸 Stitch Frame Buffered' : '🔍 [T] SCROLL TEXT EXTRACTED!',
      body: displaySnippet,
      notificationDetails: platformChannelSpecifics,
    );
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
        if (onOcrError != null) onOcrError!("No text found in screenshot.");
        return;
      }

      // If we are actively stitching, do not clutter local logs or clipboard buffers with raw slices
      if (!isStitchingModeActive) {
        await FlutterClipboard.copy(cleanText);
        await _saveToHistory(cleanText, path);
      }
      
      // Pass the active state flag down to enforce pure silence or priority audio
      await showStandoutNotification(cleanText, forceSilence: isStitchingModeActive);

      if (onOcrComplete != null) {
        onOcrComplete!(cleanText, path);
      }
    } catch (e) {
      if (onOcrError != null) onOcrError!("OCR Processing Failed: ${e.toString()}");
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

  String _cleanupText(String rawText) {
    return rawText.replaceAll('\n', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  Future<void> _saveToHistory(String text, String imagePath) async {
    final prefs = await SharedPreferences.getInstance();
    List<String> history = prefs.getStringList('ocr_history') ?? [];
    
    history.insert(0, jsonEncode({
      'text': text,
      'timestamp': DateTime.now().toIso8601String(),
      'image_path': imagePath,
    }));
    
    if (history.length > 50) history = history.sublist(0, 50);
    await prefs.setStringList('ocr_history', history);
  }

  void dispose() {
    _textRecognizer.close();
  }
}
