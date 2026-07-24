import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/ocr_service.dart';

/// The user's personal index of every PDF they saved: recipes, articles,
/// receipts — listed by the name THEY chose. Tap to open in their PDF viewer,
/// share straight to WhatsApp and friends, or delete when done.
class SavedFilesPage extends StatefulWidget {
  const SavedFilesPage({super.key});

  @override
  State<SavedFilesPage> createState() => _SavedFilesPageState();
}

class _SavedFilesPageState extends State<SavedFilesPage> {
  final OcrService _ocrService = OcrService();
  List<Map<String, dynamic>> _savedFiles = [];

  @override
  void initState() {
    super.initState();
    _loadSavedFiles();
  }

  Future<void> _loadSavedFiles() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final String rawJson = prefs.getString('saved_files_json') ?? '[]';

    List<Map<String, dynamic>> parsed = [];
    try {
      final List<dynamic> decoded = jsonDecode(rawJson);
      parsed = decoded.whereType<Map<String, dynamic>>().toList();
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _savedFiles = parsed;
    });
  }

  Future<void> _removeRecordAt(int index) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final String rawJson = prefs.getString('saved_files_json') ?? '[]';
    try {
      final List<dynamic> list = jsonDecode(rawJson);
      if (index < list.length) {
        list.removeAt(index);
        await prefs.setString('saved_files_json', jsonEncode(list));
      }
    } catch (_) {}
    await _loadSavedFiles();
  }

  Future<void> _openFile(Map<String, dynamic> entry) async {
    final String uri = entry['uri'] ?? '';
    if (uri.isEmpty) return;
    final bool opened = await _ocrService.openSavedPdf(uri);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Could not open the file. It may have been deleted, or no PDF viewer is installed.",
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _shareFile(Map<String, dynamic> entry) async {
    final String uri = entry['uri'] ?? '';
    if (uri.isEmpty) return;
    final bool shared = await _ocrService.shareSavedPdf(uri);
    if (!shared && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Could not share the file."),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _deleteFile(int index, Map<String, dynamic> entry) async {
    final String displayName = entry['name'] ?? 'this file';

    bool? confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.redAccent),
              SizedBox(width: 8),
              Expanded(
                child: Text("Delete File", overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          content: Text(
            "Permanently delete \"$displayName.pdf\" from your device?",
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

    if (confirmed == true) {
      final String uri = entry['uri'] ?? '';
      bool fileDeleted = false;
      if (uri.isNotEmpty) {
        fileDeleted = await _ocrService.deleteSavedPdf(uri);
      }
      final String thumb = entry['thumb'] ?? '';
      if (thumb.isNotEmpty) {
        try {
          await File(thumb).delete();
        } catch (_) {}
      }
      await _removeRecordAt(index);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              fileDeleted
                  ? "🗑️ \"$displayName.pdf\" deleted from your device."
                  : "Entry removed from the list.",
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  String _formatDate(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    try {
      final DateTime dt = DateTime.parse(iso);
      const months = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ];
      final String hh = dt.hour.toString().padLeft(2, '0');
      final String mm = dt.minute.toString().padLeft(2, '0');
      return '${dt.day} ${months[dt.month - 1]} ${dt.year}  $hh:$mm';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Saved Files (${_savedFiles.length})'),
        centerTitle: true,
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: _savedFiles.isEmpty
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.folder_open, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text(
                    'No saved files yet',
                    style: TextStyle(color: Colors.grey),
                  ),
                  Text(
                    'Save a card from your inbox as PDF and it will appear here!',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: MediaQuery.of(context).padding.bottom + 16,
              ),
              itemCount: _savedFiles.length,
              itemBuilder: (context, index) {
                final entry = _savedFiles[index];
                final String name = entry['name'] ?? 'Unnamed';
                final String snippet = entry['snippet'] ?? '';
                final String created = _formatDate(entry['created']);
                final String thumb = entry['thumb'] ?? '';
                final bool hasThumb =
                    thumb.isNotEmpty && File(thumb).existsSync();

                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  child: ListTile(
                    leading: hasThumb
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Image.file(
                              File(thumb),
                              width: 48,
                              height: 64,
                              fit: BoxFit.cover,
                              alignment: Alignment.topCenter,
                              errorBuilder: (_, __, ___) => const Icon(
                                Icons.picture_as_pdf,
                                color: Colors.redAccent,
                                size: 36,
                              ),
                            ),
                          )
                        : const Icon(
                            Icons.picture_as_pdf,
                            color: Colors.redAccent,
                            size: 36,
                          ),
                    title: Text(
                      '$name.pdf',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (created.isNotEmpty)
                          Text(created, style: const TextStyle(fontSize: 11)),
                        if (snippet.isNotEmpty)
                          Text(
                            snippet,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                      ],
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.share),
                          tooltip: 'Share',
                          onPressed: () => _shareFile(entry),
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.delete_outline,
                            color: Colors.redAccent,
                          ),
                          tooltip: 'Delete File',
                          onPressed: () => _deleteFile(index, entry),
                        ),
                      ],
                    ),
                    onTap: () => _openFile(entry),
                  ),
                );
              },
            ),
    );
  }
}
