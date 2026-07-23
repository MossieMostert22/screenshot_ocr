import 'package:flutter/services.dart';

/// Thin bridge to the native side. All detection, OCR, history writing,
/// clipboard and notifications now live in ScreenshotWatcherService (Kotlin),
/// which keeps running when the app is swiped away. This class only:
///   - listens for the native "onHistoryChanged" ping so the UI can refresh,
///   - forwards secure-delete requests,
///   - clears the task notification from the tray.
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

  void dispose() {}
}
