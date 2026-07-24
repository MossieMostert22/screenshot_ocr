import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:clipboard/clipboard.dart';
import 'package:path_provider/path_provider.dart';
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
              // Scrollable so the keyboard can never overflow the dialog.
              content: SingleChildScrollView(
                child: Column(
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
                        dense: true,
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

    // ---- Duplicate name check: warn before creating "name (1).pdf" copies ----
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    List<dynamic> records = [];
    try {
      records = jsonDecode(prefs.getString('saved_files_json') ?? '[]');
    } catch (_) {}
    final int existingIndex =
        records.indexWhere((e) => e is Map && e['name'] == safeName);

    bool overwrite = false;
    if (existingIndex != -1 && mounted) {
      final String? action = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text("File already exists"),
          content: Text(
            "\"$safeName.pdf\" is already in your Saved Files. What would you like to do?",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              child: const Text("Cancel"),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'keep'),
              child: const Text("Keep Both"),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, 'overwrite'),
              child: const Text("Overwrite"),
            ),
          ],
        ),
      );
      if (action == null || action == 'cancel') return;
      overwrite = action == 'overwrite';
    }

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
      if (overwrite && existingIndex != -1) {
        final Map old = records[existingIndex];
        final String oldUri = old['uri'] ?? '';
        if (oldUri.isNotEmpty) {
          await _ocrService.deleteSavedPdf(oldUri);
        }
        final String oldThumb = old['thumb'] ?? '';
        if (oldThumb.isNotEmpty) {
          try {
            await File(oldThumb).delete();
          } catch (_) {}
        }
        records.removeAt(existingIndex);
        await prefs.setString('saved_files_json', jsonEncode(records));
      }

      final Uint8List pdfBytes = await _buildPdfBytes(
        textContent,
        includeImage ? imagePath : null,
        safeName,
      );

      final Map<String, String>? saved =
          await _ocrService.savePdfToDocuments(pdfBytes, safeName);

      if (saved == null) {
        throw Exception("The file could not be written.");
      }

      // MediaStore may have auto-renamed (e.g. "name (1).pdf") — record reality.
      final String actualName = saved['name']!
          .replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '');

      // Render a first-page thumbnail for the Saved Files list.
      String thumbPath = '';
      final Uint8List? thumbBytes =
          await _ocrService.renderPdfThumbnail(saved['uri']!);
      if (thumbBytes != null) {
        try {
          final Directory docs = await getApplicationDocumentsDirectory();
          final Directory thumbsDir = Directory('${docs.path}/thumbs');
          if (!await thumbsDir.exists()) {
            await thumbsDir.create(recursive: true);
          }
          final File thumbFile = File(
            '${thumbsDir.path}/${DateTime.now().millisecondsSinceEpoch}.png',
          );
          await thumbFile.writeAsBytes(thumbBytes);
          thumbPath = thumbFile.path;
        } catch (_) {}
      }

      await _recordSavedFile(actualName, saved['uri']!, textContent, thumbPath);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "📁 Saved to Documents/Screenshot OCR/$actualName.pdf — find it in Saved Files!",
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

  Future<Uint8List> _buildPdfBytes(
    String text,
    String? imagePath,
    String title,
  ) async {
    // The user's chosen filename IS the document title — it shows in the
    // PDF header, in WhatsApp previews, and in viewer metadata.
    final pdf = pw.Document(title: '$title.pdf');

    List<pw.Widget> buildHeader() => [
          pw.Text(
            title,
            style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            "Saved via Instant Screenshot OCR",
            style:
                pw.TextStyle(fontSize: 9, color: PdfColor.fromHex('#757575')),
          ),
          pw.Divider(),
          pw.SizedBox(height: 8),
        ];

    if (imagePath != null) {
      // ONE CONTINUOUS PAGE: the page height is custom-sized to the image,
      // so screenshots (even long scroll captures) are never chopped at
      // page boundaries. No text section — the image IS the document.
      final Uint8List imgBytes = await File(imagePath).readAsBytes();
      final ui.Codec codec = await ui.instantiateImageCodec(imgBytes);
      final ui.FrameInfo frame = await codec.getNextFrame();
      final int imgW = frame.image.width;
      final int imgH = frame.image.height;
      frame.image.dispose();

      const double pageWidth = 595.28; // A4 width for familiar proportions
      const double margin = 32.0;
      const double headerHeight = 80.0;
      const double maxPageHeight = 14000.0; // PDF format ceiling ~14400pt

      double displayW = pageWidth - margin * 2;
      double displayH = imgH * (displayW / imgW);
      final double maxImageHeight = maxPageHeight - headerHeight - margin * 2;
      if (displayH > maxImageHeight) {
        final double shrink = maxImageHeight / displayH;
        displayH *= shrink;
        displayW *= shrink;
      }
      final double pageHeight = margin * 2 + headerHeight + displayH;

      final pw.MemoryImage pdfImage = pw.MemoryImage(imgBytes);
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat(pageWidth, pageHeight),
          margin: const pw.EdgeInsets.all(margin),
          build: (pw.Context context) {
            return pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                ...buildHeader(),
                pw.SizedBox(
                  width: displayW,
                  height: displayH,
                  child: pw.Image(pdfImage, fit: pw.BoxFit.fill),
                ),
              ],
            );
          },
        ),
      );
    } else {
      // Text-only: normal A4 flow.
      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(32),
          maxPages: 100,
          build: (pw.Context context) => [
            ...buildHeader(),
            pw.Paragraph(
              text: text,
              style: pw.TextStyle(fontSize: 12, lineSpacing: 1.4),
            ),
          ],
        ),
      );
    }

    return pdf.save();
  }

  Future<void> _recordSavedFile(
    String name,
    String uri,
    String sourceText,
    String thumbPath,
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
      'thumb': thumbPath,
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
                    // Bottom padding keeps the last card clear of the
                    // system navigation bar.
                    padding: EdgeInsets.only(
                      left: 16,
                      right: 16,
                      bottom: MediaQuery.of(context).padding.bottom + 16,
                    ),
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
