import 'package:flutter/material.dart';

import '../cdrom/disc_folder.dart';

/// Large directories are filtered and rendered lazily.
class GameListDialog extends StatefulWidget {
  final ScanResult scan;
  const GameListDialog({super.key, required this.scan});
  @override
  State<GameListDialog> createState() => _GameListDialogState();
}

class _GameListDialogState extends State<GameListDialog> {
  String _search = '';
  @override
  Widget build(BuildContext context) {
    final items = widget.scan.items
        .where((item) => item.path.toLowerCase().contains(_search))
        .toList();
    final skipped = widget.scan.skipped.toSet();
    return AlertDialog(
      title: Text(widget.scan.folder.name),
      content: SizedBox(
          width: 640,
          height: 480,
          child: Column(children: [
            TextField(
                autofocus: true,
                decoration: const InputDecoration(
                    hintText: 'Filter games', prefixIcon: Icon(Icons.search)),
                onChanged: (text) =>
                    setState(() => _search = text.toLowerCase())),
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
                                  ? const Text(
                                      'Missing or unreadable cue files')
                                  : null,
                              onTap: disabled
                                  ? null
                                  : () => Navigator.of(context).pop(item));
                        })),
          ])),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'))
      ],
    );
  }
}
