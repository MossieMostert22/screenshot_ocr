import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
  final ImageStitcher _imageStitcher = ImageStitcher(); // Add this line
  List<Map<String, dynamic>> _ocrHistoryList = [];
  bool _autoCopyEnabled = true;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _loadLocalHistory();
    
    // Initialize our native platform communications channel
    _ocrService.initialize();

        // Hook up background completion logic triggers with auto-eraser prompt
    _ocrService.onOcrComplete = (String extractedText, String imagePath) {
      setState(() {
        _isProcessing = false;
      });
      
      _loadLocalHistory(); // Refresh the log dashboard view list instantly

      if (_autoCopyEnabled) {
        // Show our clean floating notification alert panel choice
        showDialog(
          context: context,
          barrierDismissible: false, // User must make a dynamic choice
          builder: (BuildContext dialogContext) {
            return AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.auto_delete, color: Colors.deepPurple),
                  SizedBox(width: 8),
                  Text("Text Extracted!"),
                ],
              ),
              content: const Text(
                "The text has been copied to your clipboard. Do you want to erase the screenshot to prevent device gallery clutter?",
              ),
              actions: [
                TextButton(
                  child: const Text("Keep Image"),
                  onPressed: () {
                    Navigator.of(dialogContext).pop();
                  },
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.errorContainer,
                    foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                  child: const Text("Erase Screenshot"),
                  onPressed: () async {
                    Navigator.of(dialogContext).pop();
                    bool success = await _ocrService.deleteScreenshotFile(imagePath);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(success 
                              ? "🗑️ Screenshot deleted successfully!" 
                              : "⚠️ Could not delete file (Permission restriction)."),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    }
                  },
                ),
              ],
            );
          },
        );
      }
    };


    // Hook up error notification alerts
    _ocrService.onOcrError = (String errorMsg) {
      setState(() {
        _isProcessing = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("❌ $errorMsg"),
          backgroundColor: Theme.of(context).colorScheme.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    };
  }

  Future<void> _loadLocalHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> rawHistory = prefs.getStringList('ocr_history') ?? [];
    setState(() {
      _ocrHistoryList = rawHistory
          .map((item) => jsonDecode(item) as Map<String, dynamic>)
          .toList();
    });
  }

  Future<void> _clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('ocr_history');
    setState(() {
      _ocrHistoryList.clear();
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("History cleared.")),
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
      body: Column(
        children: [
          // Loading Status Indicator
          if (_isProcessing)
            const LinearProgressIndicator(),

          // System Control Panel
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Card(
              elevation: 2,
              child: Column(
                children: [
                  SwitchListTile(
                    title: const Text('Auto-copy to Clipboard'),
                    subtitle: const Text('Instantly inject extracted text into phone buffer'),
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

                   // Primary Navigation / Feature Launcher
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.unfold_more),
                label: const Text('Stitch & Scroll OCR'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                ),
                onPressed: _isProcessing 
                    ? null 
                    : () async {
                        setState(() {
                          _isProcessing = true;
                        });

                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text("📸 Initializing viewport stitch scan..."),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );

                        // TODO: Replicate viewport capture array. 
                        // For prototyping testing, we pass a dummy path checklist.
                        List<String> mockPaths = []; 
                        
                        if (mockPaths.isNotEmpty) {
                          final String? stitchedResultPath = 
                              await _imageStitcher.stitchImagesVertically(mockPaths);
                          
                          if (stitchedResultPath != null) {
                            await _ocrService.processScreenshot(stitchedResultPath);
                          } else {
                            _ocrService.onOcrError?.call("Stitching processing failed.");
                          }
                        } else {
                          setState(() {
                            _isProcessing = false;
                          });
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text("Simulating capture layout context. Ready for physical inputs!"),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        }
                      },
              ),
            ),
          ),


          const SizedBox(height: 16),

          // Dashboard List Title
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

          // OCR History Stream View Elements
          Expanded(
            child: _ocrHistoryList.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.center_focus_weak,
                          size: 64,
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No text scanned yet',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.outline,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Take a screenshot inside any app to start!',
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
                      final timestampStr = item['timestamp'] ?? '';
                      String formattedTime = '';
                      
                      try {
                        final parsedDate = DateTime.parse(timestampStr);
                        formattedTime = "${parsedDate.hour.toString().padLeft(2, '0')}:${parsedDate.minute.toString().padLeft(2, '0')}";
                      } catch (_) {
                        formattedTime = '';
                      }

                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 6),
                        child: ListTile(
                          title: Text(
                            textSnippet,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14),
                          ),
                          trailing: Text(
                            formattedTime,
                            style: const TextStyle(fontSize: 11, color: Colors.grey),
                          ),
                          onLongPress: () {
                            // Secondary fallback manual copy trigger
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text("Snippet selected")),
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
