// the local files given to the cdrom_image package, for the harnesses and the tests
import 'dart:io';
import 'dart:typed_data';

import 'package:cdrom_image/cdrom_image.dart';

class IoDiscFile extends DiscFile {
  final String path;
  RandomAccessFile? _file;
  Future<void> _lock = Future.value();

  IoDiscFile(this.path);

  @override
  String get name => path.split(RegExp(r'[\\/]')).last;

  Future<RandomAccessFile> _open() async => _file ??= await File(path).open();

  @override
  Future<int> length() async => (await _open()).length();

  @override
  Future<Uint8List> read(int offset, int length) {
    // a RandomAccessFile allows one pending operation at a time
    final result = _lock.then((_) async {
      final file = await _open();
      await file.setPosition(offset);
      return file.read(length);
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

class IoDiscDirectory extends DiscDirectory {
  final String root;

  IoDiscDirectory(this.root);

  @override
  String get name =>
      root.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).lastOrNull ??
      root;

  @override
  Stream<String> walk() async* {
    final dirs = <(Directory, String)>[(Directory(root), '')];
    while (dirs.isNotEmpty) {
      final (dir, prefix) = dirs.removeLast();
      try {
        await for (final e in dir.list(followLinks: false)) {
          final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
          if (e is Directory) {
            dirs.add((e, '$prefix$name/'));
          } else if (e is File) {
            yield '$prefix$name';
          }
        }
      } on FileSystemException {
        // an unreadable directory is skipped
      }
    }
  }

  @override
  DiscFile open(String path) => IoDiscFile('$root/$path');
}

/// the .cue/.iso/.bin file at [path]. the files referred from a .cue file are
/// opened relative to it.
DiscSource localDisc(String path) {
  final dir = File(path).parent.path;
  return DiscSource(IoDiscFile(path),
      (name) => IoDiscFile('$dir/${name.replaceAll('\\', '/')}'));
}
