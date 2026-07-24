import 'dart:typed_data';
import 'package:flutter/services.dart';

/// Thin bridge to the native side. All detection, OCR, history writing,
/// clipboard and notifications live in ScreenshotWatcherService (Kotlin).
/// This class handles UI refresh pings, secure delete, notification clearing,
/// and the Saved Files operations (save/open/share/delete PDFs).
class OcrService {
  static const MethodChannel _channel = MethodChannel('screenshot_channel');

  /// Fired whenever the native service finishes an OCR task while the UI is open.
  void Function()? onHistoryChanged;

  void initialize() {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method == 'onHistoryChanged') {
      onHistoryChanged?.call();
    }
  }

  Future<void> clearActiveNotificationTray() async {
    try {
      await _channel.invokeMethod('clearTaskNotification');
    } catch (_) {}
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

  // ------------------------------------------------------------------
  // Saved Files operations
  // ------------------------------------------------------------------

  /// Saves PDF bytes into public Documents/Screenshot OCR via MediaStore.
  /// Returns {'uri': contentUri, 'name': actualDisplayName} — the name can
  /// differ from the requested one if MediaStore auto-renamed a duplicate.
  Future<Map<String, String>?> savePdfToDocuments(
    Uint8List bytes,
    String fileName,
  ) async {
    try {
      final Map? res = await _channel.invokeMethod<Map>(
        'savePdfToDocuments',
        {'bytes': bytes, 'fileName': fileName},
      );
      if (res == null) return null;
      final String? uri = res['uri'] as String?;
      final String? name = res['name'] as String?;
      if (uri == null || name == null) return null;
      return {'uri': uri, 'name': name};
    } catch (_) {
      return null;
    }
  }

  /// Renders the first page of a saved PDF as a small PNG thumbnail.
  Future<Uint8List?> renderPdfThumbnail(String uri) async {
    try {
      return await _channel.invokeMethod<Uint8List>(
        'renderPdfThumbnail',
        {'uri': uri},
      );
    } catch (_) {
      return null;
    }
  }

  /// Opens the saved PDF with the user's default viewer.
  Future<bool> openSavedPdf(String uri) async {
    try {
      return await _channel.invokeMethod<bool>('openSavedPdf', {'uri': uri}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the system share sheet with the PDF attached.
  Future<bool> shareSavedPdf(String uri) async {
    try {
      return await _channel.invokeMethod<bool>('shareSavedPdf', {'uri': uri}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Permanently deletes a saved PDF from the device.
  Future<bool> deleteSavedPdf(String uri) async {
    try {
      return await _channel.invokeMethod<bool>('deleteSavedPdf', {'uri': uri}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  void dispose() {}
}
