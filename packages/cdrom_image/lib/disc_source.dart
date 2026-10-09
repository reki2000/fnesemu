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
