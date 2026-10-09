import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../cdrom/disc_scanner.dart';

/// Large directories are filtered and rendered lazily. While the directory is
/// being scanned ([scan] is null), the dialog shows the [progress] instead.
class GameListDialog extends StatefulWidget {
  final String title;
  final ValueListenable<ScanResult?> scan;
  final ValueListenable<ScanProgress?>? progress;

  /// removes the directory from the directory menu
  final VoidCallback? onRemove;

  const GameListDialog(
      {super.key,
      required this.title,
      required this.scan,
      this.progress,
      this.onRemove});

  @override
  State<GameListDialog> createState() => _GameListDialogState();
}

class _GameListDialogState extends State<GameListDialog> {
  String _search = '';

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: SizedBox(
            width: 640,
            height: 480,
            child: ValueListenableBuilder<ScanResult?>(
                valueListenable: widget.scan,
                builder: (context, scan, _) =>
                    scan == null ? _scanning() : _list(scan))),
        actions: [
          if (widget.onRemove != null)
            TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  widget.onRemove!();
                },
                child: const Text('Remove Directory')),
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'))
        ],
      );

  Widget _scanning() {
    final progress = widget.progress;
    if (progress == null) return const SizedBox();
    return ValueListenableBuilder<ScanProgress?>(
        valueListenable: progress,
        builder: (context, p, _) => Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(p == null ? 'Scanning' : 'Scanning: $p'),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                    value: p == null || p.isListing || p.cues == 0
                        ? null
                        : p.checkedCues / p.cues),
              ],
            ));
  }

  Widget _list(ScanResult scan) {
    final items = scan.items
        .where((item) => item.path.toLowerCase().contains(_search))
        .toList();
    final skipped = scan.skipped.toSet();
    return Column(children: [
      TextField(
          autofocus: true,
          decoration: const InputDecoration(
              hintText: 'Filter games', prefixIcon: Icon(Icons.search)),
          onChanged: (text) => setState(() => _search = text.toLowerCase())),
      const SizedBox(height: 8),
      Expanded(
          child: items.isEmpty
              ? const Center(child: Text('No files'))
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final disabled = skipped.contains(item.path);
                    return ListTile(
                        title: Text(item.path),
                        enabled: !disabled,
                        subtitle: disabled
                            ? const Text('Missing or unreadable cue files')
                            : null,
                        onTap: disabled
                            ? null
                            : () => Navigator.of(context).pop(item));
                  })),
    ]);
  }
}
