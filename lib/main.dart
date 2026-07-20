import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services/ocr_service.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Instant Screenshot OCR',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      ),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  static const _channel = MethodChannel('screenshot_channel');

  bool _autoCopyToClipboard = true;
  bool _isScanning = false;
  String? _activeAlert;
  String? _latestScreenshotPath;
  final List<_ScanEntry> _history = <_ScanEntry>[];
  late final OcrService _ocrService;

  @override
  void initState() {
    super.initState();
    _ocrService = OcrService(onCopyCompleted: _showCopyCompletion);
    _channel.setMethodCallHandler(_handleScreenshotMethod);
    Future<void>.microtask(() => _ocrService.handleScreenshotPath(null));
  }

  Future<void> _handleScreenshotMethod(MethodCall call) async {
    if (call.method == 'onScreenshotTaken') {
      final path = call.arguments?.toString();
      if (path != null && path.isNotEmpty) {
        setState(() {
          _latestScreenshotPath = path;
          _activeAlert = 'Screenshot captured: $path';
          _history.insert(0, _ScanEntry(snippet: path, source: 'System screenshot'));
        });
        await _ocrService.handleScreenshotPath(path);
      }
    }
  }

  void _showCopyCompletion(String message) {
    if (!mounted) {
      return;
    }
    setState(() {
      _activeAlert = message;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _handleBackgroundClipboardMatch(String match) {
    if (!mounted) {
      return;
    }

    setState(() {
      _activeAlert = 'Clipboard match detected: $match';
      _history.insert(0, _ScanEntry(snippet: match, source: 'Background match'));
    });
  }

  Future<void> _runStitchPreview() async {
    setState(() => _isScanning = true);

    final viewports = <String>[
      'Viewport 1 • top section',
      'Viewport 2 • mid section',
      'Viewport 3 • footer',
    ];

    for (final viewport in viewports) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (!mounted) {
        return;
      }
      setState(() {
        _history.insert(0, _ScanEntry(snippet: viewport, source: 'Stitch preview'));
      });
    }

    await _ocrService.runBackgroundClipboardMatch();

    if (!mounted) {
      return;
    }
    setState(() => _isScanning = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Instant Screenshot OCR'),
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        toolbarHeight: 84,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: ListView(
            children: [
              Text(
                'Capture, review, and keep OCR results in sync.',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: _activeAlert == null
                    ? const SizedBox.shrink(key: ValueKey('empty'))
                    : Container(
                        key: ValueKey(_activeAlert),
                        margin: const EdgeInsets.only(bottom: 16),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.notifications_active_rounded,
                              color: theme.colorScheme.onPrimaryContainer,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _activeAlert!,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onPrimaryContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.history_rounded,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Recent OCR snippets',
                            style: theme.textTheme.titleMedium,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_history.isEmpty)
                        Text(
                          'No scans captured yet',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        )
                      else
                        ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: _history.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final entry = _history[index];
                            return Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surface,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    entry.snippet,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodyMedium,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    entry.source,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                ),
              ),
              if (_latestScreenshotPath != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'Latest screenshot path: $_latestScreenshotPath',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Auto-copy to clipboard'),
                subtitle: const Text('Send OCR output to your clipboard when a match is found.'),
                value: _autoCopyToClipboard,
                onChanged: (value) {
                  setState(() => _autoCopyToClipboard = value);
                },
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _isScanning ? null : _runStitchPreview,
                icon: _isScanning
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome_rounded),
                label: Text(_isScanning ? 'Scanning viewports…' : 'Stitch & Scroll OCR'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScanEntry {
  const _ScanEntry({required this.snippet, required this.source});

  final String snippet;
  final String source;
}
