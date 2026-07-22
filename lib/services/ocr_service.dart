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

      for (String itemStr in history) {
        try {
          Map<String, dynamic> existingEntry = jsonDecode(itemStr);
          String existingText = existingEntry['text'] ?? '';
          String oldImagePath = existingEntry['image_path'] ?? '';

          if (existingText.isNotEmpty) {
            if (cleanText.length > existingText.length && cleanText.contains(existingText.substring(0, existingText.length > 30 ? 30 : existingText.length))) {
              itemsToRemove.add(itemStr);
              if (oldImagePath.isNotEmpty && oldImagePath != path) {
                await deleteScreenshotFile(oldImagePath);
              }
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
