import 'dart:convert';

import 'filesystem_api.dart';

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

  /// [resolve] returns the file of a name written in the .cue file, or throws
  /// if there is not
  DiscSource(this.main, DiscFile Function(String name) resolve)
      : _resolve = resolve;

  String get name => main.path;

  bool get isCue => name.toLowerCase().endsWith(".cue");

  /// Resolves a file referred to by the image description, without opening it.
  DiscFile resolve(String name) => _resolve(name);
}

Future<String> readText(DiscFile file, {int? maxBytes}) async {
  var length = await file.length();
  if (maxBytes != null && length > maxBytes) length = maxBytes;
  return utf8.decode(await file.read(0, length), allowMalformed: true);
}
