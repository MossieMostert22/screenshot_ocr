import 'dart:io';

import 'package:clipboard/clipboard.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

class OcrService {
  OcrService({void Function(String message)? onCopyCompleted})
      : _onCopyCompleted = onCopyCompleted {
    _channel.setMethodCallHandler(_handleScreenshotMethod);
  }

  static const MethodChannel _channel = MethodChannel('screenshot_channel');

  final TextRecognizer _textRecognizer = TextRecognizer(
    script: TextRecognitionScript.latin,
  );
  final void Function(String message)? _onCopyCompleted;
  void Function(String match)? onBackgroundClipboardMatch;

  Future<void> handleScreenshotPath(String? filePath) async {
    if (filePath == null || filePath.trim().isEmpty) {
      return;
    }

    final inputImage = InputImage.fromFilePath(filePath);
    final recognizedText = await _textRecognizer.processImage(inputImage);
    final cleanedText = _cleanRecognizedText(recognizedText.text);

    if (cleanedText.isEmpty) {
      _notifyCopyCompleted('No text found in screenshot.');
      return;
    }

    await FlutterClipboard.copy(cleanedText);
    _notifyCopyCompleted('OCR text copied to clipboard.');
  }

  Future<void> _handleScreenshotMethod(MethodCall call) async {
    if (call.method == 'onScreenshotTaken') {
      await handleScreenshotPath(call.arguments?.toString());
    }
  }

  Future<void> runBackgroundClipboardMatch() async {
    await Future<void>.microtask(() {});
    final match = 'Invoice #1042 • Due today';
    onBackgroundClipboardMatch?.call(match);
  }

  String _cleanRecognizedText(String rawText) {
    final lines = rawText
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();

    final buffer = StringBuffer();
    for (final line in lines) {
      if (buffer.isNotEmpty) {
        buffer.write('\n');
      }
      buffer.write(line.replaceAll(RegExp(r'\s+'), ' '));
    }

    return buffer.toString();
  }

  void _notifyCopyCompleted(String message) {
    _onCopyCompleted?.call(message);
  }
}
