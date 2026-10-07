import 'dart:io';
import 'dart:typed_data';

import '../api.dart';

/// a local file
class IoReadFile extends RandomReadFile {
  final String path;
  @override
  final String? restoreKey;
  RandomAccessFile? _file;
  Future<void> _lock = Future.value();

  IoReadFile(this.path, {this.restoreKey});

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

/// a local directory
class IoDirectory extends PickedDirectory {
  final String root;
  @override
  String get identityKey => root;
  @override
  final String? restoreKey;

  /// restored by [root]
  IoDirectory(this.root) : restoreKey = root;

  /// restored by [restoreKey] which the platform gives, or not if null
  IoDirectory.withKey(this.root, this.restoreKey);

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
  RandomReadFile open(String path) => IoReadFile('$root/$path');
}
