/// disc images on memory, for tests
library;

import 'dart:typed_data';

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

/// files on memory, by their paths. [files] are given to [DiscImage.parse].
class MemoryDirectory {
  final Map<String, MemoryDiscFile> files;

  MemoryDirectory(this.files);

  MemoryDirectory.of(Map<String, Uint8List> data)
      : files = {
          for (final e in data.entries) e.key: MemoryDiscFile(e.key, e.value)
        };
}

/// the arguments of [DiscImage.parse] for the disc image [main] of [files]
(DiscFile, Iterable<DiscFile>) memoryDisc(
        String main, Map<String, MemoryDiscFile> files) =>
    (files[main]!, files.values);
