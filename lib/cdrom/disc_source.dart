import 'dart:convert';

import 'package:mp_bigfile_picker/api.dart';

/// a disc image: a .cue file with the files it refers to, or a single
/// .iso/.bin file
class DiscSource {
  /// .cue, .iso or .bin
  final RandomReadFile main;

  final RandomReadFile Function(String name) _resolve;
  final _opened = <RandomReadFile>[];

  /// [resolve] returns the file of a name written in the .cue file, or throws
  /// if there is not
  DiscSource(this.main, RandomReadFile Function(String name) resolve)
      : _resolve = resolve;

  /// the image at [path] of [dir]. the files referred from the .cue file are
  /// searched in [files], the paths of [PickedDirectory.walk], ignoring the
  /// case.
  factory DiscSource.inDirectory(
      PickedDirectory dir, String path, Iterable<String> files) {
    final index = {for (final f in files) folderKey('', f)!: f};
    return DiscSource(dir.open(path), (name) {
      final key = folderKey(dirOf(path), name);
      final found = key == null ? null : index[key];
      if (found == null) {
        throw ArgumentError("cdrom: file not found in the folder: $name");
      }
      return dir.open(found);
    });
  }

  String get name => main.name;

  bool get isCue => name.toLowerCase().endsWith(".cue");

  /// opens a file referred from the .cue file
  RandomReadFile open(String name) {
    final file = _resolve(name);
    _opened.add(file);
    return file;
  }

  /// closes all files opened by this source
  Future<void> close() async {
    await main.close();
    for (final f in _opened) {
      await f.close();
    }
    _opened.clear();
  }
}

Future<String> readText(RandomReadFile file, {int? maxBytes}) async {
  var length = await file.length();
  if (maxBytes != null && length > maxBytes) length = maxBytes;
  return utf8.decode(await file.read(0, length), allowMalformed: true);
}

/// normalizes a path written in a .cue file ('\' or '/', '.', '..') relative
/// to [baseDir] ('' or 'a/b'), into a lower case key. returns null if it goes
/// out of the folder.
String? folderKey(String baseDir, String name) {
  final parts = <String>[];
  final all = [
    ...baseDir.split('/'),
    ...name.replaceAll('\\', '/').split('/'),
  ];
  for (final p in all) {
    if (p.isEmpty || p == '.') continue;
    if (p == '..') {
      if (parts.isEmpty) return null;
      parts.removeLast();
    } else {
      parts.add(p);
    }
  }
  return parts.join('/').toLowerCase();
}

String dirOf(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? '' : path.substring(0, i);
}
