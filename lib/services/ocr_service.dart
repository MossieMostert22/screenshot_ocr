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
  
  // Track notification IDs to support instant clearing layouts
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

  /// Fires a clean sound alert based on the user's dashboard configuration setting
  Future<void> showSingleTaskNotification(String snippetText, bool isSoundActive) async {
    final AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      // FIXED: Uses dynamic channel toggling to bypass Android's immutable channel cache bug
      isSoundActive ? 'ocr_inbox_sound_chan_v6' : 'ocr_inbox_mute_chan_v6',
      isSoundActive ? 'Audible Task Inbox Alerts' : 'Silent Task Inbox Alerts',
      channelDescription: 'Handles incoming text notifications based on dashboard settings',
      importance: isSoundActive ? Importance.max : Importance.low,
      priority: isSoundActive ? Priority.high : Priority.low,
      playSound: isSoundActive, 
      enableVibration: isSoundActive,
      showWhen: true,
      styleInformation: const BigTextStyleInformation(''),
    );
    
    final NotificationDetails platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);
    
    String displaySnippet = snippetText.length > 45 ? '${snippetText.substring(0, 45)}...' : snippetText;

    // FIXED: Named parameters matching latest library rules
    await _notificationsPlugin.show(
      id: _taskNotificationId, 
      title: '📩 NEW TEXT EXTRACTED!',
      body: displaySnippet,
      notificationDetails: platformChannelSpecifics,
    );
  }

  /// Instantly wipes our application's notification banner from the top system tray
  Future<void> clearActiveNotificationTray() async {
    // FIXED: Explicitly named the target cancel ID parameter
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

      await FlutterClipboard.copy(cleanText);
      await _saveToHistory(cleanText, path);
      
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

