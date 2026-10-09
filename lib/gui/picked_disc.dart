// gives the files of mp_bigfile_picker to the cdrom package
import 'dart:typed_data';

import 'package:cdrom/cdrom.dart';
import 'package:mp_bigfile_picker/api.dart';

class PickedDiscFile extends DiscFile {
  final RandomReadFile file;

  PickedDiscFile(this.file);

  @override
  String get name => file.name;

  @override
  Future<int> length() => file.length();

  @override
  Future<Uint8List> read(int offset, int length) => file.read(offset, length);

  @override
  Future<void> close() => file.close();
}

class PickedDiscDirectory extends DiscDirectory {
  final PickedDirectory dir;

  PickedDiscDirectory(this.dir);

  @override
  String get name => dir.name;

  @override
  Stream<String> walk() => dir.walk();

  @override
  DiscFile open(String path) => PickedDiscFile(dir.open(path));
}
