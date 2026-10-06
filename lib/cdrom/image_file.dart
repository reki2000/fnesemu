import 'dart:convert';
import 'dart:typed_data';

import 'package:mp_bigfile_picker/api.dart';

/// random access to a disc image file. implemented per platform.
abstract class ImageFile {
  String get name;

  Future<int> length();

  /// reads [length] bytes from [offset]. may return less bytes at the end of
  /// the file.
  Future<Uint8List> read(int offset, int length);

  Future<void> close();

  Future<String> readText() async =>
      utf8.decode(await read(0, await length()), allowMalformed: true);
}

/// an [ImageFile] of a [RandomReadFile] of mp_bigfile_picker
class PickedImageFile extends ImageFile {
  final RandomReadFile file;

  PickedImageFile(this.file);

  @override
  String get name => file.name;

  @override
  Future<int> length() => file.length();

  @override
  Future<Uint8List> read(int offset, int length) => file.read(offset, length);

  @override
  Future<void> close() => file.close();
}

/// a disc image: a .cue file with its track files, or a single .iso/.bin file
abstract class DiscSource {
  /// .cue, .iso or .bin
  ImageFile get main;

  /// opens a file referred from the .cue file
  Future<ImageFile> open(String name);

  String get name => main.name;

  bool get isCue => name.toLowerCase().endsWith(".cue");

  /// closes all files opened by this source
  Future<void> close();
}

/// an [ImageFile] on memory, for tests
class MemoryImageFile extends ImageFile {
  @override
  final String name;
  final Uint8List data;

  /// called on each [read], for tests
  void Function(int offset, int length)? onRead;

  MemoryImageFile(this.name, this.data);

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

class MemoryDiscSource extends DiscSource {
  final Map<String, MemoryImageFile> files;
  final String mainName;

  MemoryDiscSource(this.mainName, this.files);

  @override
  ImageFile get main => files[mainName]!;

  @override
  Future<ImageFile> open(String name) async =>
      files[name] ?? (throw ArgumentError("file not found: $name"));

  @override
  Future<void> close() async {}
}
