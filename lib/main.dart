import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:clipboard/clipboard.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'services/ocr_service.dart';
import 'services/image_stitcher.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ScreenshotOcrApp());
}

class ScreenshotOcrApp extends StatelessWidget {
  const ScreenshotOcrApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Instant Screenshot OCR',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final OcrService _ocrService = OcrService();
  final ImageStitcher _imageStitcher = ImageStitcher();

  List<Map<String, dynamic>> _ocrHistoryList = [];
  bool _autoCopyEnabled = true;
  bool _isProcessing = false;
  String _stitchingStatusText = "";

  @override
  void initState() {
    super.initState();
    _requestAppPermissions();
    _initForegroundTask();
    _loadLocalHistory();

    _ocrService.initialize();

    _ocrService.onOcrComplete = (String extractedText, String imagePath) {
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _stitchingStatusText = "";
      });

      _loadLocalHistory();

      if (_autoCopyEnabled) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("✨ Long text extracted & copied to clipboard!"),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 2),
          ),
        );
      }
    };

    _ocrService.onOcrError = (String errorMsg) {
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _stitchingStatusText = "";
      });
      _ocrService.isStitchingModeActive = false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("❌ $errorMsg"),
          backgroundColor: Theme.of(context).colorScheme.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    };
  }

  Future<void> _requestAppPermissions() async {
    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
    }
    if (await Permission.systemAlertWindow.isDenied) {
      await Permission.systemAlertWindow.request();
    }
  }

       void _initForegroundTask() {
    // FIXED: Removed the unsupported notificationMode property and const keywords for version 10+
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'foreground_service_channel',
        channelName: 'Foreground Service Notification',
        channelDescription: 'Keeps background capture loops active during stitching tasks.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
      ),
    );
  }




  Future<void> _loadLocalHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> rawHistory = prefs.getStringList('ocr_history') ?? [];
    if (!mounted) return;
    setState(() {
      _ocrHistoryList = rawHistory
          .map((item) => jsonDecode(item) as Map<String, dynamic>)
          .toList();
    });
  }

  Future<void> _clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('ocr_history');
    if (!mounted) return;
    setState(() {
      _ocrHistoryList.clear();
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text("History cleared.")));
  }

  Future<void> _inlineDeleteEntry(int index, String imagePath) async {
    bool fileDeleted = await _ocrService.deleteScreenshotFile(imagePath);

    final prefs = await SharedPreferences.getInstance();
    List<String> rawHistory = prefs.getStringList('ocr_history') ?? [];

    if (index < rawHistory.length) {
      rawHistory.removeAt(index);
      await prefs.setStringList('ocr_history', rawHistory);
      await _loadLocalHistory();
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            fileDeleted
                ? "🗑️ Log entry and screenshot file erased completely!"
                : "Log snippet entry removed from application dashboard views.",
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _executeStitchAndScrollOcr() async {
    if (!mounted) return;
    setState(() {
      _isProcessing = true;
      _stitchingStatusText =
          "📸 Listening for multi-capture scroll sequence...";
    });

    _ocrService.isStitchingModeActive = true;

    // Securely launch the un-killable background priority execution service container
    await FlutterForegroundTask.startService(
      notificationTitle: 'Screenshot OCR Active',
      notificationText:
          'Monitoring scrolling viewports in silent capture mode...',
    );

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Start snapping successive views! (Target: 3 frames)"),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 3),
      ),
    );

    List<String> capturedViewports = [];
    int expectedCapturesCount = 3;

    final oldCallback = _ocrService.onOcrComplete;

    _ocrService.onOcrComplete = (String extractedText, String imagePath) {
      capturedViewports.add(imagePath);

      if (!mounted) return;
      setState(() {
        _stitchingStatusText =
            "Captured frame block (${capturedViewports.length}/$expectedCapturesCount)";
      });

      if (capturedViewports.length >= expectedCapturesCount) {
        _ocrService.onOcrComplete = oldCallback;
        _processStitchedCompilationPipeline(capturedViewports);
      }
    };
  }

  Future<void> _processStitchedCompilationPipeline(List<String> paths) async {
    if (!mounted) return;
    setState(() {
      _stitchingStatusText = "🧩 Blending pixel borders vertically...";
    });

    final String? stitchedMegaImagePath = await _imageStitcher
        .stitchImagesVertically(paths);

    _ocrService.isStitchingModeActive = false;

    // Stop the foreground service since our background loop is complete
    await FlutterForegroundTask.stopService();

    if (stitchedMegaImagePath != null) {
      if (!mounted) return;
      setState(() {
        _stitchingStatusText =
            "🔎 Extracting combined paragraph text blocks...";
      });
      await _ocrService.processScreenshot(stitchedMegaImagePath);
    } else {
      _ocrService.onOcrError?.call(
        "Vertical image matrix layout compilation collapsed.",
      );
    }
  }

  @override
  void dispose() {
    _ocrService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Instant Screenshot OCR'),
        centerTitle: true,
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          if (_ocrHistoryList.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: 'Clear All History',
              onPressed: _clearHistory,
            ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Card(
                  elevation: 2,
                  child: Column(
                    children: [
                      SwitchListTile(
                        title: const Text('Auto-copy to Clipboard'),
                        subtitle: const Text(
                          'Instantly inject extracted text into phone buffer',
                        ),
                        value: _autoCopyEnabled,
                        onChanged: (bool value) {
                          setState(() {
                            _autoCopyEnabled = value;
                          });
                        },
                      ),
                    ],
                  ),
                ),
              ),

              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.unfold_more),
                    label: const Text('Stitch & Scroll OCR'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.primaryContainer,
                    ),
                    onPressed: _isProcessing
                        ? null
                        : _executeStitchAndScrollOcr,
                  ),
                ),
              ),

              const SizedBox(height: 16),

              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Recent Snippets (${_ocrHistoryList.length})',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 8),

              Expanded(
                child: _ocrHistoryList.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.center_focus_weak,
                              size: 64,
                              color: Theme.of(
                                context,
                              ).colorScheme.outlineVariant,
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              'No text scanned yet',
                              style: TextStyle(color: Colors.grey),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Take a screenshot inside any app to start!',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: _ocrHistoryList.length,
                        itemBuilder: (context, index) {
                          final item = _ocrHistoryList[index];
                          final textSnippet = item['text'] ?? '';
                          final timestampStr = item['timestamp'] ?? '';
                          final savedImagePath = item['image_path'] ?? '';
                          String formattedTime = '';

                          try {
                            final parsedDate = DateTime.parse(timestampStr);
                            formattedTime =
                                "${parsedDate.hour.toString().padLeft(2, '0')}:${parsedDate.minute.toString().padLeft(2, '0')}";
                          } catch (_) {}

                          return Card(
                            margin: const EdgeInsets.symmetric(vertical: 6),
                            child: ListTile(
                              title: Text(
                                textSnippet,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 14),
                              ),
                              subtitle: Text(
                                formattedTime,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey,
                                ),
                              ),
                              trailing: IconButton(
                                icon: const Icon(
                                  Icons.delete_outline,
                                  color: Colors.redAccent,
                                ),
                                tooltip: 'Erase Log & Screenshot File',
                                onPressed: () =>
                                    _inlineDeleteEntry(index, savedImagePath),
                              ),
                              onLongPress: () {
                                FlutterClipboard.copy(textSnippet).then((
                                  dynamic _,
                                ) {
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text("✨ Copied to clipboard!"),
                                    ),
                                  );
                                });
                              },
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
          if (_isProcessing && _stitchingStatusText.isNotEmpty)
            Container(
              color: Colors.black.withValues(alpha: 0.75),
              child: Center(
                child: Card(
                  margin: const EdgeInsets.all(32),
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 24),
                        Text(
                          _stitchingStatusText,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          "Keep scrolling and snapping views sequentially.",
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
