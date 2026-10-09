part of 'app.dart';

/// lets the user select files and reads them. returns null when cancelled.
/// the dialog opens at [initialDirectory], and [onDirectory] receives the
/// directory of the selected files when it is a local path.
Future<List<(Uint8List, String)>?> _pickFiles(
    {bool multiple = false,
    String? dialogTitle,
    String? initialDirectory,
    void Function(String directory)? onDirectory}) async {
  final files = await pickFiles(
      multiple: multiple,
      dialogTitle: dialogTitle,
      initialDirectory: initialDirectory);
  if (files == null || files.isEmpty) {
    return null;
  }

  final directory = _localDirectoryOf(files.first.restoreKey);
  if (directory != null) onDirectory?.call(directory);

  return [for (final file in files) await _readPicked(file)];
}

/// the directory of a local file path ('/...' or 'C:\\...'), or null for
/// other restore keys (content uris, bookmarks) and the web
String? _localDirectoryOf(String? path) {
  if (path == null || !path.startsWith(RegExp(r'/|[A-Za-z]:\\'))) {
    return null;
  }
  final i = path.lastIndexOf(RegExp(r'[/\\]'));
  return i <= 0 ? null : path.substring(0, i);
}

/// a local directory path, or null (content uris, bookmarks, the web)
String? _localPath(String? path) =>
    path != null && path.startsWith(RegExp(r'/|[A-Za-z]:\\')) ? path : null;

Future<(Uint8List, String)> _readPicked(RandomReadFile file) async {
  try {
    return (await file.read(0, await file.length()), file.name);
  } catch (e) {
    throw Exception("failed to read: ${file.name}: $e");
  } finally {
    await file.close();
  }
}
