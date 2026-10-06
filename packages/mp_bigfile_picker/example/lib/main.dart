import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:mp_bigfile_picker/mp_bigfile_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const MaterialApp(home: ExamplePage()));

class ExamplePage extends StatefulWidget {
  const ExamplePage({super.key});

  @override
  State<ExamplePage> createState() => _ExamplePageState();
}

class _ExamplePageState extends State<ExamplePage> {
  static const _dirKey = 'restore_key';
  static const _filesKey = 'restore_file_keys';

  /// the title: the directory, or the picked files
  String _title = 'mp_bigfile_picker';

  /// the files listed, by the path in the directory or the name
  List<String> _files = [];
  RandomReadFile Function(String) _openFile = (_) => throw StateError('none');
  bool _walking = false;
  String _log = '';

  @override
  void initState() {
    super.initState();
    _restore();
  }

  void _print(String s) => setState(() => _log = '$s\n$_log');

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString(_dirKey);
    if (key != null) {
      final dir = await restoreDirectory(key);
      _print(dir == null ? 'restore failed: $key' : 'restored: ${dir.name}');
      if (dir != null) await _open(dir);
      return;
    }
    final keys = prefs.getStringList(_filesKey);
    if (keys != null) {
      final files = <RandomReadFile>[];
      for (final k in keys) {
        final f = await restoreFile(k);
        _print(f == null ? 'restore failed: $k' : 'restored: ${f.name}');
        if (f != null) files.add(f);
      }
      _showFiles(files);
    }
  }

  /// saves the restore keys of the directory or the files
  Future<void> _save({String? dirKey, List<String>? fileKeys}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_dirKey);
    await prefs.remove(_filesKey);
    if (dirKey != null) await prefs.setString(_dirKey, dirKey);
    if (fileKeys != null) await prefs.setStringList(_filesKey, fileKeys);
  }

  Future<void> _pickFiles() async {
    final files = await pickFiles(multiple: true, dialogTitle: 'Select files');
    if (files == null) {
      _print('canceled');
      return;
    }
    final keys = files.map((f) => f.restoreKey).toList();
    await _save(fileKeys: keys.contains(null) ? null : keys.cast<String>());
    _print('picked: ${files.length} files\nrestore keys: $keys');
    _showFiles(files);
  }

  void _showFiles(List<RandomReadFile> files) {
    final byName = {for (final f in files) f.name: f};
    setState(() {
      _title = '${files.length} files';
      _files = byName.keys.toList()..sort();
      _openFile = (name) => byName[name]!;
    });
  }

  Future<void> _pick() async {
    final dir = await pickDirectory(dialogTitle: 'Select a directory');
    if (dir == null) {
      _print('canceled');
      return;
    }
    final key = dir.restoreKey;
    await _save(dirKey: key);
    _print('picked: ${dir.name}\nrestore key: $key');
    await _open(dir);
  }

  Future<void> _open(PickedDirectory dir) async {
    setState(() {
      _title = dir.name;
      _openFile = dir.open;
      _files = [];
      _walking = true;
    });
    final sw = Stopwatch()..start();
    final files = <String>[];
    await for (final path in dir.walk()) {
      files.add(path);
    }
    files.sort();
    setState(() {
      _files = files;
      _walking = false;
    });
    _print('walk: ${files.length} files in ${sw.elapsedMilliseconds} ms');
  }

  /// reads the head, the tail and random sectors of the file
  Future<void> _read(String path) async {
    final file = _openFile(path);
    try {
      final sw = Stopwatch()..start();
      final length = await file.length();
      final head = await file.read(0, 16);
      final tail = await file.read(max(0, length - 16), 16);

      const sector = 2352, count = 256;
      final rand = Random();
      int bytes = 0;
      final t = Stopwatch()..start();
      for (int i = 0; i < count; i++) {
        final offset = length <= sector ? 0 : rand.nextInt(length - sector);
        bytes += (await file.read(offset, sector)).length;
      }
      final us = t.elapsedMicroseconds;

      _print('$path: $length bytes (${sw.elapsedMilliseconds} ms)\n'
          '  head: ${_hex(head)}\n'
          '  tail: ${_hex(tail)}\n'
          '  $count random reads of $sector bytes: $bytes bytes, '
          '${(us / count).toStringAsFixed(1)} us/read');
    } catch (e) {
      _print('$path: $e');
    } finally {
      await file.close();
    }
  }

  static String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        actions: [
          IconButton(
              onPressed: _pickFiles,
              icon: const Icon(Icons.file_open),
              tooltip: 'Pick files'),
          IconButton(
              onPressed: _pick,
              icon: const Icon(Icons.folder_open),
              tooltip: 'Pick a directory'),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            flex: 3,
            child: _walking
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: _files.length,
                    itemBuilder: (_, i) => ListTile(
                      dense: true,
                      title: Text(_files[i]),
                      onTap: () => _read(_files[i]),
                    ),
                  ),
          ),
          const Divider(height: 1),
          Expanded(
            flex: 2,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(8),
              child: SelectableText(_log,
                  style:
                      const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }
}
