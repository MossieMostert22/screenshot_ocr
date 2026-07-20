import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:clipboard/clipboard.dart';
import 'package:shared_preferences/shared_preferences.dart';

class OcrService {
  static const MethodChannel _channel = MethodChannel('screenshot_channel');
  final TextRecognizer _textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
  
  // Callback functions to alert the UI layers
  Function(String)? onOcrComplete;
  Function(String)? onOcrError;

  void initialize() {
    _channel.setMethodCallHandler(_handleMethodCall);
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

      // 1. Copy directly to system clipboard
      await FlutterClipboard.copy(cleanText);

      // 2. Save code block to local storage history
      await _saveToHistory(cleanText);

      // 3. Inform active UI listeners
      if (onOcrComplete != null) {
        onOcrComplete!(cleanText);
      }
    } catch (e) {
      if (onOcrError != null) onOcrError!("OCR Processing Failed: ${e.toString()}");
    }
  }

  String _cleanupText(String rawText) {
    // Normalizes multi-line layout blocks into continuous flowing reader paragraphs
    return rawText.replaceAll('\n', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  Future<void> _saveToHistory(String text) async {
    final prefs = await SharedPreferences.getInstance();
    List<String> history = prefs.getStringList('ocr_history') ?? [];
    
    // Keep history lean and performant; insert new item at the top
    history.insert(0, jsonEncode({
      'text': text,
      'timestamp': DateTime.now().toIso8601String(),
    }));
    
    // Cap maximum log elements to 50 entries
    if (history.length > 50) history = history.sublist(0, 50);
    await prefs.setStringList('ocr_history', history);
  }

  void dispose() {
    _textRecognizer.close();
  }
}
