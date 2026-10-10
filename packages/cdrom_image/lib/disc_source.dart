// internal: the files of a disc image, for the parser
import 'dart:convert';

import 'filesystem_api.dart';
import 'image_api.dart';

/// a disc image: a .cue file with the files it refers to, or a single
/// .iso/.bin file
class DiscSource {
  /// .cue, .iso or .bin
  final DiscFile main;

  /// [_key] of the path -> file
  final Map<String, DiscFile> _index;

  /// the files the .cue file refers to, by [resolve]
  final referenced = <String, DiscFile>{};

  /// [files] are the files of the directory of [main]
  DiscSource(Iterable<DiscFile> files, this.main)
      : _index = {
          for (final f in [...files, main]) _key('', f.path)!: f
        };

  String get name => main.path;

  bool get isCue => name.toLowerCase().endsWith(".cue");

  /// the file of [name] written in the .cue file: relative to the .cue file,
  /// ignoring the case. throws if it is not in the directory.
  DiscFile resolve(String name) {
    final key = _key(_dirOf(main.path), name);
    final file = key == null ? null : _index[key];
    if (file == null) {
      throw DiscParseException(main.path, 'Referenced file not found: $name',
          referencedPath: name);
    }
    if (file.path != main.path) referenced[file.path] = file;
    return file;
  }

  /// normalizes a path written in a .cue file ('\' or '/', '.', '..')
  /// relative to [baseDir] ('' or 'a/b'), into a lower case key. returns null
  /// if it goes out of the directory.
  static String? _key(String baseDir, String name) {
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

  static String _dirOf(String path) {
    final i = path.lastIndexOf('/');
    return i < 0 ? '' : path.substring(0, i);
  }
}

Future<String> readText(DiscFile file) async =>
    utf8.decode(await file.read(0, await file.length()), allowMalformed: true);
