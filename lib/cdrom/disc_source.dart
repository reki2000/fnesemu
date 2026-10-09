import 'dart:convert';
import 'dart:typed_data';

/// a file read at any offset. given by the app.
abstract class DiscFile {
  String get name;

  Future<int> length();

  /// reads [length] bytes from [offset]. may return less bytes at the end of
  /// the file.
  Future<Uint8List> read(int offset, int length);

  /// the file is opened again by the next [read]
  Future<void> close();
}

/// a directory of disc images. given by the app.
abstract class DiscDirectory {
  String get name;

  /// the paths of the files below the directory, relative to it and separated
  /// by '/'
  Stream<String> walk();

  /// the file at a path of [walk]. it is opened when it is read.
  DiscFile open(String path);
}

/// whether a file can be a disc image, by its name
enum DiscFileKind {
  /// .cue or .iso
  image,

  /// .bin: a raw disc image, or a ROM
  maybeImage,

  notImage;

  static DiscFileKind of(String name) =>
      switch (name.substring(name.lastIndexOf('.') + 1).toLowerCase()) {
        'cue' || 'iso' => image,
        'bin' => maybeImage,
        _ => notImage,
      };
}

/// a disc image: a .cue file with the files it refers to, or a single
/// .iso/.bin file
class DiscSource {
  /// .cue, .iso or .bin
  final DiscFile main;

  final DiscFile Function(String name) _resolve;
  final _opened = <DiscFile>[];

  /// [resolve] returns the file of a name written in the .cue file, or throws
  /// if there is not
  DiscSource(this.main, DiscFile Function(String name) resolve)
      : _resolve = resolve;

  /// the image at [path] of [dir]. the files referred from the .cue file are
  /// searched in [files], the paths of [DiscDirectory.walk], ignoring the
  /// case.
  factory DiscSource.inDirectory(
      DiscDirectory dir, String path, Iterable<String> files) {
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
  DiscFile open(String name) {
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

Future<String> readText(DiscFile file, {int? maxBytes}) async {
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
