// Adapts picker files to the resource-free virtual file API.
import 'dart:typed_data';

import 'package:cdrom_image/filesystem_api.dart';
import 'package:fnesemu_core/app_api.dart';
import 'package:mp_bigfile_picker/api.dart';

final _log = DebugLog('app.disc');

class PickedDiscFile extends DiscFile {
  @override
  final String path;
  final RandomReadFile Function() _file;

  PickedDiscFile(this.path, this._file);

  @override
  Future<int> length() async {
    final file = _file();
    try {
      return await file.length();
    } finally {
      await file.close();
    }
  }

  @override
  Future<Uint8List> read(int offset, int length) async {
    final watch = Stopwatch()..start();
    final file = _file();
    try {
      return await file.read(offset, length);
    } finally {
      await file.close();
      _log.debugc(() => "read $path $offset+$length "
          "in ${watch.elapsedMilliseconds}ms");
    }
  }
}

/// the files below [dir]
Stream<DiscFile> pickedDiscFiles(PickedDirectory dir) =>
    dir.walk().map((path) => PickedDiscFile(path, () => dir.open(path)));
