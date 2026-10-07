// the platform independent interface. no dependency on dart:io or flutter.
import 'dart:typed_data';

/// a file read at any offset, without loading the whole
abstract class RandomReadFile {
  String get name;

  /// a key to open the file again after a restart by `restoreFile`, or null if
  /// it cannot (the web, or a file in a [PickedDirectory])
  String? get restoreKey => null;

  Future<int> length();

  /// reads [length] bytes from [offset]. returns less bytes at the end of the
  /// file.
  Future<Uint8List> read(int offset, int length);

  /// the file is opened again by the next [read]
  Future<void> close();
}

/// a directory selected by the user
abstract class PickedDirectory {
  String get name;

  /// the full path to show to the user, or [name] where the platform does
  /// not give one (the web)
  String get displayPath => name;

  /// a key to open the directory again after a restart by
  /// `restoreDirectory`, or null in browsers without persistent directory access.
  String? get restoreKey;

  /// Stable directory identity, independent of a renewed permission token.
  /// Use [restoreKey], rather than this identity, to restore access.
  String? get identityKey => restoreKey;

  /// the paths of the files below the directory, relative to it and separated
  /// by '/'
  Stream<String> walk();

  /// the file at a path of [walk]. it is opened when it is read.
  RandomReadFile open(String path);
}
