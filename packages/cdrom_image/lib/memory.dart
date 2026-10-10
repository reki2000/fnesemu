/// disc images on memory, for tests
library;

import 'dart:typed_data';

import 'disc_folder.dart';
import 'disc_source.dart';
import 'filesystem_api.dart';

class MemoryDiscFile extends DiscFile {
  @override
  final String path;
  final Uint8List data;

  /// called on each [read]
  void Function(int offset, int length)? onRead;

  MemoryDiscFile(this.path, this.data);

  @override
  Future<int> length() async => data.length;

  @override
  Future<Uint8List> read(int offset, int length) async {
    onRead?.call(offset, length);
    final start = offset.clamp(0, data.length);
    final end = (offset + length).clamp(0, data.length);
    return Uint8List.sublistView(data, start, end);
  }
}

class MemoryDirectory extends DiscDirectory {
  final Map<String, MemoryDiscFile> files;

  MemoryDirectory(this.files);

  MemoryDirectory.of(Map<String, Uint8List> data)
      : files = {
          for (final e in data.entries) e.key: MemoryDiscFile(e.key, e.value)
        };

  @override
  Stream<DiscFile> walk() => Stream.fromIterable(files.values);
}

/// the disc image [main] of [files]
DiscSource memoryDisc(String main, Map<String, MemoryDiscFile> files) =>
    DiscFolder(files.values).source(main);
