import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:clipboard/clipboard.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf/pdf.dart';
import 'services/ocr_service.dart';
import 'saved_files_page.dart';

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
    _initializeApplicationSequence();
  }

  Future<void> _initializeApplicationSequence() async {
    await _requestAppPermissions();
    await _loadLocalAppSettings();
    await _loadLocalHistory();
    _ocrService.initialize();

    // The native ScreenshotWatcherService does all detection/OCR. It pings
    // us here (only while the UI is open) so the inbox refreshes instantly.
    _ocrService.onHistoryChanged = () async {
      await _loadLocalHistory();
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
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _ocrService.clearActiveNotificationTray();
      // The service may have processed screenshots while we were away.
      _loadLocalHistory();
    }
  }

  Future<void> _requestAppPermissions() async {
    // photos → READ_MEDIA_IMAGES on Android 13+. The background watcher needs
    // it to read new screenshot files. IMPORTANT: the user must pick
    // "Allow all" — limited access would hide future screenshots from us.
    Map<Permission, PermissionStatus> statuses = await [
      Permission.notification,
      Permission.photos,
    ].request();

    if (statuses[Permission.notification]?.isDenied ?? false) {
      await Permission.notification.request();
    }
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
    // IMPORTANT: the native service writes history from outside the Flutter
    // cache, so we must reload from disk before reading.
    await prefs.reload();

    String? rawJson = prefs.getString('ocr_history_json');

    // One-time migration from the old List<String> storage format.
    if (rawJson == null) {
      final List<String>? legacy = prefs.getStringList('ocr_history');
      if (legacy != null && legacy.isNotEmpty) {
        rawJson = '[${legacy.join(',')}]';
        await prefs.setString('ocr_history_json', rawJson);
        await prefs.remove('ocr_history');
      }
    }

    if (!mounted) return;
    List<Map<String, dynamic>> parsed = [];
    try {
      final List<dynamic> decoded = jsonDecode(rawJson ?? '[]');
      parsed = decoded.whereType<Map<String, dynamic>>().toList();
    } catch (_) {}

    setState(() {
      _ocrHistoryList = parsed;
    });
  }

  // ------------------------------------------------------------------
  // PDF export: screenshot image (sliced across pages) + extracted text,
  // saved through MediaStore and indexed in the Saved Files screen.
  // ------------------------------------------------------------------

  Future<void> _exportToPdfFlow(String textContent, String imagePath) async {
    final TextEditingController fileNameController = TextEditingController();
    final bool imageAvailable =
        imagePath.isNotEmpty && await File(imagePath).exists();
    bool includeImage = imageAvailable;

    String? chosenName = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text("Save to Documents"),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: fileNameController,
                    decoration: const InputDecoration(
                      hintText: "Enter custom filename (e.g. MyRecipe)",
                      suffixText: ".pdf",
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (imageAvailable)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        "Include screenshot image",
                        style: TextStyle(fontSize: 14),
                      ),
                      value: includeImage,
                      onChanged: (v) {
                        setDialogState(() {
                          includeImage = v ?? true;
                        });
                      },
                    ),
                ],
              ),
              actions: [
                TextButton(
                  child: const Text("Cancel"),
                  onPressed: () => Navigator.of(context).pop(null),
                ),
                ElevatedButton(
                  child: const Text("Save"),
                  onPressed: () {
                    if (fileNameController.text.trim().isNotEmpty) {
                      Navigator.of(context).pop(fileNameController.text.trim());
                    }
                  },
                ),
              ],
            );
          },
        );
      },
    );

    if (chosenName == null || chosenName.isEmpty) return;

    // Strip characters Android filenames can't contain.
    final String safeName =
        chosenName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '').trim();
    if (safeName.isEmpty) return;

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("⏳ Building your PDF..."),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
    }

    try {
      final Uint8List pdfBytes = await _buildPdfBytes(
        textContent,
        includeImage ? imagePath : null,
      );

      final String? savedUri =
          await _ocrService.savePdfToDocuments(pdfBytes, safeName);

      if (savedUri == null) {
        throw Exception("The file could not be written.");
      }

      await _recordSavedFile(safeName, savedUri, textContent);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "📁 Saved to Documents/Screenshot OCR/$safeName.pdf — find it in Saved Files!",
            ),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("❌ Failed to save: ${e.toString()}"),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<Uint8List> _buildPdfBytes(String text, String? imagePath) async {
    final pdf = pw.Document();
    final List<pw.Widget> content = [
      pw.Text(
        "Extracted Task Document",
        style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold),
      ),
      pw.SizedBox(height: 8),
      pw.Text(
        "Saved via Instant Screenshot OCR",
        style: pw.TextStyle(fontSize: 10, color: PdfColor.fromHex('#757575')),
      ),
      pw.Divider(),
      pw.SizedBox(height: 12),
    ];

    if (imagePath != null) {
      final List<Uint8List> slices = await _sliceImageForPdf(imagePath);
      for (final slice in slices) {
        content.add(
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 6),
            child: pw.Image(pw.MemoryImage(slice), fit: pw.BoxFit.fitWidth),
          ),
        );
      }
      if (slices.isNotEmpty) {
        content.add(pw.SizedBox(height: 12));
        content.add(pw.Divider());
        content.add(pw.SizedBox(height: 12));
        content.add(
          pw.Text(
            "Extracted Text",
            style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
          ),
        );
        content.add(pw.SizedBox(height: 8));
      }
    }

    content.add(
      pw.Paragraph(
        text: text,
        style: pw.TextStyle(fontSize: 12, lineSpacing: 1.4),
      ),
    );

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        maxPages: 100,
        build: (pw.Context context) => content,
      ),
    );

    return pdf.save();
  }

  /// Cuts a (possibly very tall scroll-capture) screenshot into page-sized
  /// horizontal slices so the PDF shows the WHOLE image across multiple
  /// pages instead of one unreadably shrunken thumbnail.
  Future<List<Uint8List>> _sliceImageForPdf(String path) async {
    try {
      final Uint8List bytes = await File(path).readAsBytes();
      final ui.Codec codec = await ui.instantiateImageCodec(bytes);
      final ui.FrameInfo frame = await codec.getNextFrame();
      final ui.Image fullImage = frame.image;

      // A4 content area at 32pt margins: ~531pt wide. Keep each slice's
      // rendered height under ~690pt so every slice fits one page.
      const double contentWidthPts = 531.0;
      const double sliceHeightPts = 690.0;
      final double scale = contentWidthPts / fullImage.width;
      final int sliceHeightPx = math.max(1, (sliceHeightPts / scale).floor());

      final List<Uint8List> slices = [];
      int y = 0;
      while (y < fullImage.height) {
        final int h = math.min(sliceHeightPx, fullImage.height - y);

        final ui.PictureRecorder recorder = ui.PictureRecorder();
        final Canvas canvas = Canvas(recorder);
        canvas.drawImageRect(
          fullImage,
          Rect.fromLTWH(
            0,
            y.toDouble(),
            fullImage.width.toDouble(),
            h.toDouble(),
          ),
          Rect.fromLTWH(
            0,
            0,
            fullImage.width.toDouble(),
            h.toDouble(),
          ),
          Paint(),
        );
        final ui.Picture picture = recorder.endRecording();
        final ui.Image sliceImage = await picture.toImage(fullImage.width, h);
        final ByteData? byteData =
            await sliceImage.toByteData(format: ui.ImageByteFormat.png);
        if (byteData != null) {
          slices.add(byteData.buffer.asUint8List());
        }
        sliceImage.dispose();
        picture.dispose();
        y += h;
      }
      fullImage.dispose();
      return slices;
    } catch (_) {
      // Image unreadable (deleted, moved, permission) → text-only PDF.
      return [];
    }
  }

  Future<void> _recordSavedFile(
    String name,
    String uri,
    String sourceText,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final String rawJson = prefs.getString('saved_files_json') ?? '[]';

    List<dynamic> list = [];
    try {
      list = jsonDecode(rawJson);
    } catch (_) {}

    final String snippet = sourceText.length > 60
        ? '${sourceText.substring(0, 60)}...'
        : sourceText;

    list.insert(0, {
      'name': name,
      'uri': uri,
      'created': DateTime.now().toIso8601String(),
      'snippet': snippet,
    });

    await prefs.setString('saved_files_json', jsonEncode(list));
  }

  // ------------------------------------------------------------------
  // Inbox card deletion (unchanged behavior)
  // ------------------------------------------------------------------

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
      await prefs.reload();
      final String rawJson = prefs.getString('ocr_history_json') ?? '[]';

      try {
        final List<dynamic> list = jsonDecode(rawJson);
        if (index < list.length) {
          list.removeAt(index);
          await prefs.setString('ocr_history_json', jsonEncode(list));
        }
      } catch (_) {}
      await _loadLocalHistory();

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

  @override void
  dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ocrService.dispose();
    super.dispose();
  }

  @override Widget
  build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Instant Screenshot OCR'),
        centerTitle: true,
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_special),
            tooltip: 'Saved Files',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const SavedFilesPage()),
              );
            },
          ),
        ],
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
                                  ElevatedButton.icon(
                                    icon: const Icon(Icons.picture_as_pdf),
                                    label: const Text("Save to File"),
                                    onPressed: () {
                                      Navigator.pop(context);
                                      _exportToPdfFlow(
                                        textSnippet,
                                        savedImagePath,
                                      );
                                    },
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
