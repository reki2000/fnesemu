// local files by dart:io. no dependency on flutter, for command line tools
import 'dart:io';

import 'package:mp_bigfile_picker/io.dart';

import 'disc_folder.dart';
import 'image_file.dart';

class IoImageFile extends PickedImageFile {
  final String path;

  IoImageFile(this.path) : super(IoReadFile(path));
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

/// a local directory
class LocalDiscFolder extends PickedDiscFolder {
  LocalDiscFolder(String root) : super(IoDirectory(root));
}
