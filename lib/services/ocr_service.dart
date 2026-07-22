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
    
    await _notificationsPlugin.initialize(
      settings: initializationSettings,
    );
  }

  /// Shows the notification tray icon in both modes, but completely disables sound when muted
  Future<void> showSingleTaskNotification(String snippetText, bool isSoundActive) async {
    final AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      isSoundActive ? 'ocr_sound_channel_v7' : 'ocr_mute_channel_v7',
      isSoundActive ? 'Audible Task Alerts' : 'Silent Task Alerts',
      channelDescription: 'Handles incoming text notifications based on dashboard settings',
      // FIXED: Kept at Max so the visual icon sits in your top bar tray safely
      importance: Importance.max,
      priority: Priority.high,
      playSound: isSoundActive, // FIXED: Explicitly turns off the sound channel track
      enableVibration: isSoundActive, // FIXED: Turns off vibration mechanics
      showWhen: true,
      styleInformation: const BigTextStyleInformation(''),
    );
    
    final NotificationDetails platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);
    
    String displaySnippet = snippetText.length > 45 ? '${snippetText.substring(0, 45)}...' : snippetText;

    await _notificationsPlugin.show(
      id: _taskNotificationId, 
      title: '📩 NEW TEXT EXTRACTED!',
      body: displaySnippet,
      notificationDetails: platformChannelSpecifics,
    );
  }

  Future<void> clearActiveNotificationTray() async {
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

      // FIXED: Smart Text Overlap Filter Engine
      List<String> history = prefs.getStringList('ocr_history') ?? [];
      
      if (history.isNotEmpty) {
        Map<String, dynamic> lastEntry = jsonDecode(history.first);
        String lastExtractedText = lastEntry['text'] ?? '';
        
        // If the old text is found inside the new longer text, erase the old temporary segment card instantly
        if (cleanText.contains(lastExtractedText) || lastExtractedText.contains(cleanText.substring(0, lastExtractedText.length > cleanText.length ? cleanText.length : lastExtractedText.length))) {
          // Permanently erase the old file path reference from storage to prevent gallery clutter
          String oldImagePath = lastEntry['image_path'] ?? '';
          if (oldImagePath.isNotEmpty && oldImagePath != path) {
            await deleteScreenshotFile(oldImagePath);
          }
          history.removeAt(0); // Pop old card segment from the history stack layout
        }
      }

      // Automatically push the newest complete paragraph block text to clip board buffer
      await FlutterClipboard.copy(cleanText);
      
      // Update history storage list layout bounds
      history.insert(0, jsonEncode({
        'text': cleanText,
        'timestamp': DateTime.now().toIso8601String(),
        'image_path': path,
      }));
      
      if (history.length > 50) history = history.sublist(0, 50);
      await prefs.setStringList('ocr_history', history);
      
      await showSingleTaskNotification(cleanText, userSoundSetting);

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

  String _cleanupText(String rawText) {
    return rawText.replaceAll('\n', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  void dispose() {
    _textRecognizer.close();
  }
}
