// the local files given to the cdrom_image package, for the harnesses and the tests
import 'dart:io';
import 'dart:typed_data';

import 'package:cdrom_image/cdrom_image.dart';

class IoDiscFile extends DiscFile {
  final File _file;
  @override
  final String path;

  IoDiscFile(String location, {String? relativePath})
      : _file = File(location),
        path = relativePath ?? location.split(RegExp(r'[\\/]')).last;

  @override
  Future<int> length() => _file.length();

  @override
  Future<Uint8List> read(int offset, int length) async {
    final file = await _file.open();
    try {
      await file.setPosition(offset);
      return await file.read(length);
    } finally {
      await file.close();
    }
  }
}

class IoDiscDirectory extends DiscDirectory {
  final String root;

  IoDiscDirectory(this.root);

  @override
  Stream<DiscFile> walk() async* {
    final dirs = <(Directory, String)>[(Directory(root), '')];
    while (dirs.isNotEmpty) {
      final (dir, prefix) = dirs.removeLast();
      try {
        await for (final e in dir.list(followLinks: false)) {
          final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
          if (e is Directory) {
            dirs.add((e, '$prefix$name/'));
          } else if (e is File) {
            yield IoDiscFile(e.path, relativePath: '$prefix$name');
          }
        }
      } on FileSystemException {
        // an unreadable directory is skipped
      }
    }
  }
}

/// the .cue/.iso/.bin file at [path]. the files referred from a .cue file are
/// opened relative to it.
DiscSource localDisc(String path) {
  final dir = File(path).parent.path;
  return DiscSource(IoDiscFile(path),
      (name) => IoDiscFile('$dir/${name.replaceAll('\\', '/')}'));
}
