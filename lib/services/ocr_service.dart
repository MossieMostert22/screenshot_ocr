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

  /// Keeps the visual tray notifications icon sitting on your top bar tray safely until swiped or cleared out
  Future<void> showSingleTaskNotification(String snippetText, bool isSoundActive) async {
    final AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      // FIXED: Uses distinct channel registry profiles to force Android to display the status bar icon visuals
      isSoundActive ? 'ocr_sound_tray_chan_v8' : 'ocr_silent_tray_chan_v8',
      isSoundActive ? 'Audible Task Tray Notifications' : 'Silent Task Tray Notifications',
      channelDescription: 'Fires text extraction indicators to status trays securely',
      importance: Importance.max, // FIXED: High priority ensures the icon stays stuck on top of the screen
      priority: Priority.high,
      playSound: isSoundActive, 
      enableVibration: isSoundActive,
      showWhen: true,
      ongoing: false, // Allows users to swipe it away manually whenever they choose
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

      List<String> history = prefs.getStringList('ocr_history') ?? [];
      List<String> itemsToRemove = [];

      // FIXED: Global Text Matrix Contraction Filter Engine iterating across all local task inbox profiles
      for (String itemStr in history) {
        try {
          Map<String, dynamic> existingEntry = jsonDecode(itemStr);
          String existingText = existingEntry['text'] ?? '';
          String oldImagePath = existingEntry['image_path'] ?? '';

          if (existingText.isNotEmpty) {
            // If the old text segment matches or overlaps our new text block, queue the old card for full deletion
            if (cleanText.contains(existingText) || existingText.contains(cleanText) || 
                (cleanText.length > 15 && existingText.contains(cleanText.substring(0, 15)))) {
              itemsToRemove.add(itemStr);
              if (oldImagePath.isNotEmpty && oldImagePath != path) {
                await deleteScreenshotFile(oldImagePath); // Delete incomplete screenshot files from gallery storage
              }
            }
          }
        } catch (_) {}
      }

      // Drop all incomplete matched artifacts instantly out of our history logs list stack
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