/// picks a directory and reads the files below it at any offset, without
/// copying them.
///
/// - Android: a directory of the Storage Access Framework. the files are read
///   by pread(2) on the file descriptors of the documents.
/// - iOS: a security scoped directory, read by dart:io.
/// - desktop: a local directory, read by dart:io.
/// - web: a directory input, read by Blob.slice.
library;

export 'api.dart';
export 'src/picker_io.dart' if (dart.library.js_interop) 'src/picker_web.dart';
