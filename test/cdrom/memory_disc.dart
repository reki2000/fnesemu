// disc images on memory, for tests
import 'dart:typed_data';

import 'package:fnesemu/cdrom/disc_source.dart';
import 'package:mp_bigfile_picker/api.dart';

class MemoryReadFile extends RandomReadFile {
  @override
  final String name;
  final Uint8List data;

  /// called on each [read]
  void Function(int offset, int length)? onRead;

  MemoryReadFile(this.name, this.data);

  @override
  Future<int> length() async => data.length;

  @override
  Future<Uint8List> read(int offset, int length) async {
    onRead?.call(offset, length);
    final start = offset.clamp(0, data.length);
    final end = (offset + length).clamp(0, data.length);
    return Uint8List.sublistView(data, start, end);
  }

  @override
  Future<void> close() async {}
}

class MemoryDirectory extends PickedDirectory {
  final Map<String, MemoryReadFile> files;

  MemoryDirectory(this.files);

  MemoryDirectory.of(Map<String, Uint8List> data)
      : files = {for (final e in data.entries) e.key: MemoryReadFile(e.key, e.value)};

  @override
  String get name => 'memory';

  @override
  String? get restoreKey => null;

  @override
  Stream<String> walk() => Stream.fromIterable(files.keys);

  @override
  RandomReadFile open(String path) =>
      files[path] ?? (throw ArgumentError("file not found: $path"));
}

/// the disc image [main] of [files]
DiscSource memoryDisc(String main, Map<String, MemoryReadFile> files) =>
    DiscSource.inDirectory(MemoryDirectory(files), main, files.keys);
