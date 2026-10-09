// a directory of mp_bigfile_picker on memory, for tests
import 'dart:typed_data';

import 'package:mp_bigfile_picker/api.dart';

class MemoryPickedFile extends RandomReadFile {
  @override
  final String name;
  final Uint8List data;

  MemoryPickedFile(this.name, this.data);

  @override
  Future<int> length() async => data.length;

  @override
  Future<Uint8List> read(int offset, int length) async =>
      Uint8List.sublistView(data, offset.clamp(0, data.length),
          (offset + length).clamp(0, data.length));

  @override
  Future<void> close() async {}
}

class MemoryPickedDirectory extends PickedDirectory {
  final Map<String, Uint8List> files;

  MemoryPickedDirectory(this.files);

  @override
  String get name => 'memory';

  @override
  String? get restoreKey => null;

  @override
  Stream<String> walk() => Stream.fromIterable(files.keys);

  @override
  RandomReadFile open(String path) => MemoryPickedFile(
      path, files[path] ?? (throw ArgumentError("file not found: $path")));
}
