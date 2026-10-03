import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'image_file.dart';

class IoImageFile extends ImageFile {
  final String path;
  RandomAccessFile? _file;
  Future<void> _lock = Future.value();

  IoImageFile(this.path);

  @override
  String get name => path.split(RegExp(r'[\\/]')).last;

  Future<RandomAccessFile> _open() async => _file ??= await File(path).open();

  @override
  Future<int> length() async => (await _open()).length();

  @override
  Future<Uint8List> read(int offset, int length) {
    // RandomAccessFile allows only one pending operation at a time
    final result = _lock.then((_) async {
      final file = await _open();
      await file.setPosition(offset);
      return await file.read(length);
    });
    _lock = result.then((_) {}, onError: (_) {});
    return result;
  }

  @override
  Future<void> close() async {
    final file = _file;
    _file = null;
    await _lock;
    await file?.close();
  }
}

class IoDiscSource extends DiscSource {
  final IoImageFile _main;
  final _opened = <IoImageFile>[];

  IoDiscSource(String path) : _main = IoImageFile(path);

  @override
  ImageFile get main => _main;

  @override
  Future<ImageFile> open(String name) async {
    final path = "${File(_main.path).parent.path}/$name";
    if (!await File(path).exists()) {
      throw ArgumentError("cdrom: file not found: $path");
    }
    final file = IoImageFile(path);
    _opened.add(file);
    return file;
  }

  @override
  Future<void> close() async {
    await _main.close();
    for (final f in _opened) {
      await f.close();
    }
    _opened.clear();
  }
}

/// returns a disc image of the local file at [path]
DiscSource discSourceFromPath(String path) => IoDiscSource(path);

/// lets the user select a .cue, .iso or .bin file. returns null if canceled.
Future<DiscSource?> pickDiscSource() async {
  final picked = await FilePicker.platform.pickFiles(
      dialogTitle: "Select a disc image (.cue, .iso, .bin)",
      type: FileType.custom,
      allowedExtensions: ["cue", "iso", "bin", "img"]);
  final path = picked?.files.firstOrNull?.path;
  return path == null ? null : IoDiscSource(path);
}
