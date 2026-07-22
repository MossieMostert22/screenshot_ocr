import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:clipboard/clipboard.dart';
import 'services/ocr_service.dart';

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

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final OcrService _ocrService = OcrService();
  List<Map<String, dynamic>> _ocrHistoryList = [];
  bool _autoCopyEnabled = true;
  bool _soundAlertsEnabled = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _requestAppPermissions();
    _loadLocalAppSettings();
    _loadLocalHistory();
    _ocrService.initialize();

    _ocrService.onOcrComplete = (String extractedText, String imagePath) {
      _loadLocalHistory();
      if (_autoCopyEnabled && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "✨ Text extracted & copied to clipboard! Check your inbox list below.",
            ),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 3),
          ),
        );
      }
    };

    _ocrService.onOcrError = (String errorMsg) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("❌ $errorMsg"),
          behavior: SnackBarBehavior.floating,
        ),
      );
    };
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Clear out active tray notifications immediately when entering the app screen layout manually
    if (state == AppLifecycleState.resumed) {
      _ocrService.clearActiveNotificationTray();
    }
  }

  Future<void> _requestAppPermissions() async {
    await [Permission.notification, Permission.systemAlertWindow].request();
  }

  Future<void> _loadLocalAppSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _autoCopyEnabled = prefs.getBool('ocr_auto_copy') ?? true;
      _soundAlertsEnabled = prefs.getBool('ocr_sound_enabled') ?? true;
    });
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

  /// FIXED: Wrapped using an Expanded text structural container block to erase right side overflow stripes layout bugs completely
  Future<void> _triggerSecureDeleteFlow(int index, String imagePath) async {
    bool? userConfirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.redAccent),
              SizedBox(width: 8),
              Expanded(
                // FIXED: Prevents text pixel widths from spilling over off edge boundaries layout lines
                child: Text("Confirm Erasure", overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          content: const Text(
            "This will delete the screenshot from your device permanently, are you sure?",
          ),
          actions: [
            TextButton(
              child: const Text("No"),
              onPressed: () => Navigator.of(dialogContext).pop(false),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.errorContainer,
                foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
              ),
              child: const Text("Yes"),
              onPressed: () => Navigator.of(dialogContext).pop(true),
            ),
          ],
        );
      },
    );

    if (userConfirmed == true) {
      _ocrService.clearActiveNotificationTray();
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
                  ? "🗑️ Screenshot file and log entry permanently erased!"
                  : "Inbox entry removed from application view profile logs.",
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }


  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12.0),
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
                    onChanged: (bool value) async {
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setBool('ocr_auto_copy', value);
                      setState(() {
                        _autoCopyEnabled = value;
                      });
                    },
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  SwitchListTile(
                    title: const Text('Notification Sound Effects'),
                    subtitle: const Text(
                      'Enable audio beep sounds when text parsing completes',
                    ),
                    value: _soundAlertsEnabled,
                    onChanged: (bool value) async {
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setBool('ocr_sound_enabled', value);
                      setState(() {
                        _soundAlertsEnabled = value;
                      });
                    },
                  ),
                ],
              ),
            ),
          ),

          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 24.0,
              vertical: 4.0,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Your Task Inbox (${_ocrHistoryList.length})',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
          ),

          Expanded(
            child: _ocrHistoryList.isEmpty
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.mail_outline, size: 64, color: Colors.grey),
                        SizedBox(height: 16),
                        Text(
                          'Your processing inbox is empty',
                          style: TextStyle(color: Colors.grey),
                        ),
                        Text(
                          'Take a standard or scroll screenshot to populate!',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
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
                      final savedImagePath = item['image_path'] ?? '';

                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 6),
                        child: ListTile(
                          title: Text(
                            textSnippet,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14),
                          ),
                          trailing: IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              color: Colors.redAccent,
                            ),
                            tooltip: 'Erase Screenshot File & Log',
                            onPressed: () =>
                                _triggerSecureDeleteFlow(index, savedImagePath),
                          ),
                          onTap: () {
                            showDialog(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: const Text("Extracted Task Content"),
                                content: SingleChildScrollView(
                                  child: Text(textSnippet),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(context),
                                    child: const Text("Close"),
                                  ),
                                  ElevatedButton(
                                    onPressed: () {
                                      FlutterClipboard.copy(textSnippet);
                                      Navigator.pop(context);
                                    },
                                    child: const Text("Copy Text"),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
