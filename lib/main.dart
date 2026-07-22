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
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple, brightness: Brightness.light),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple, brightness: Brightness.dark),
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
  List<Map<String, dynamic>> _ocrHistoryList = [];
  bool _autoCopyEnabled = true;

  @override
  void initState() {
    super.initState();
    _requestAppPermissions();
    _loadLocalHistory();
    _ocrService.initialize();

    // Fires exactly ONCE when Android completely finishes saving a screenshot file
    _ocrService.onOcrComplete = (String extractedText, String imagePath) {
      _loadLocalHistory(); // Auto-refresh our inbox list view model layout instantly
      if (_autoCopyEnabled && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("✨ Text extracted & copied to clipboard! Check your inbox list below."),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 3),
          ),
        );
      }
    };

    _ocrService.onOcrError = (String errorMsg) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("❌ $errorMsg"), behavior: SnackBarBehavior.floating),
      );
    };
  }

  Future<void> _requestAppPermissions() async {
    await [Permission.notification, Permission.systemAlertWindow].request();
  }

  Future<void> _loadLocalHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> rawHistory = prefs.getStringList('ocr_history') ?? [];
    if (!mounted) return;
    setState(() {
      _ocrHistoryList = rawHistory.map((item) => jsonDecode(item) as Map<String, dynamic>).toList();
    });
  }

  Future<void> _inlineDeleteEntry(int index, String imagePath) async {
    // 1. Permanently delete the screenshot image file from the phone storage gallery
    bool fileDeleted = await _ocrService.deleteScreenshotFile(imagePath);
    
    // 2. Clear out the inbox card log from our dashboard history log list
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
          content: Text(fileDeleted 
              ? "🗑️ Screenshot file and log entry permanently erased!" 
              : "Inbox entry removed from application view profile logs."),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _clearAllHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('ocr_history');
    if (!mounted) return;
    setState(() {
      _ocrHistoryList.clear();
    });
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
              tooltip: 'Clear All Task Logs',
              onPressed: _clearAllHistory,
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Card(
              elevation: 2,
              child: SwitchListTile(
                title: const Text('Auto-copy to Clipboard'),
                subtitle: const Text('Instantly inject extracted text into phone buffer'),
                value: _autoCopyEnabled,
                onChanged: (bool value) {
                  setState(() {
                    _autoCopyEnabled = value;
                  });
                },
              ),
            ),
          ),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Your Task Inbox (${_ocrHistoryList.length})',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
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
                        Text('Your processing inbox is empty', style: TextStyle(color: Colors.grey)),
                        Text('Take a standard or scroll screenshot to populate!', style: TextStyle(fontSize: 12, color: Colors.grey)),
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
                          title: Text(textSnippet, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                            tooltip: 'Erase Screenshot File & Log',
                            onPressed: () => _inlineDeleteEntry(index, savedImagePath),
                          ),
                          onTap: () {
                            // Let the user view or share the full text when tapping the inbox entry card
                            showDialog(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: const Text("Extracted Task Content"),
                                content: SingleChildScrollView(child: Text(textSnippet)),
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
