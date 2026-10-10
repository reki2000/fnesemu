import 'dart:typed_data';

/// A file whose operations acquire and release their own resources.
abstract class DiscFile {
  /// Relative to the containing directory, separated by `/`.
  String get path;

  /// Returns the byte length, releasing resources even on failure.
  Future<int> length();

  /// Reads bytes at an absolute offset; returns fewer bytes at EOF.
  /// Offsets and lengths are nonnegative. Resources are released before
  /// completing, including on failure. Concurrent calls must be independent.
  Future<Uint8List> read(int offset, int length);
}

/// Files below a directory. Enumeration order is unspecified.
abstract class DiscDirectory {
  /// Recursively yields files with paths relative to this directory.
  /// Enumeration does not open their contents.
  Stream<DiscFile> walk();
}
