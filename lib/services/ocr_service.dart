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

  /// Plays exactly ONE pleasant priority alert sound when the complete text extraction finishes
  Future<void> showSingleTaskNotification(String snippetText) async {
    const AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      'ocr_task_inbox_channel_v1',
      'Task Inbox Notifications',
      channelDescription: 'Fires one clean sound alert per finalized screenshot text extraction',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true, 
      enableVibration: true,
      showWhen: true,
      styleInformation: BigTextStyleInformation(''),
    );
    
    const NotificationDetails platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);
    
    String displaySnippet = snippetText.length > 45 ? '${snippetText.substring(0, 45)}...' : snippetText;

    await _notificationsPlugin.show(
      id: DateTime.now().millisecondsSinceEpoch ~/ 1000, // Unique task ID matching your email inbox analogy
      title: '📩 NEW TEXT EXTRACTED!',
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
        return; // Quietly ignore empty images without throwing annoying errors
      }

      // Copy directly to the system clip board automatically
      await FlutterClipboard.copy(cleanText);
      
      // Save it into our shared persistent history file log
      await _saveToHistory(cleanText, path);
      
      // Fire exactly ONE priority alert notification block
      await showSingleTaskNotification(cleanText);

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
