// Adapts picker files to the resource-free virtual file API.
import 'dart:typed_data';

import 'package:cdrom_image/filesystem_api.dart';
import 'package:mp_bigfile_picker/api.dart';

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
    final file = _file();
    try {
      return await file.read(offset, length);
    } finally {
      await file.close();
    }
  }
}

class PickedDiscDirectory extends DiscDirectory {
  final PickedDirectory dir;

  PickedDiscDirectory(this.dir);

  @override
  Stream<DiscFile> walk() =>
      dir.walk().map((path) => PickedDiscFile(path, () => dir.open(path)));
}
