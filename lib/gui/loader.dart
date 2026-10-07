part of 'app.dart';

String _fileExtension(String fileName) =>
    fileName.substring(fileName.lastIndexOf(".") + 1).toLowerCase();

/// lets the user select files and reads them. returns null when cancelled.
Future<List<(Uint8List, String)>?> _pickFiles(
    {bool multiple = false, String? dialogTitle}) async {
  final files = await pickFiles(multiple: multiple, dialogTitle: dialogTitle);
  if (files == null || files.isEmpty) {
    return null;
  }

  return [for (final file in files) await _readPicked(file)];
}

Future<(Uint8List, String)> _readPicked(RandomReadFile file) async {
  try {
    return (await file.read(0, await file.length()), file.name);
  } catch (e) {
    throw Exception("failed to read: ${file.name}: $e");
  } finally {
    await file.close();
  }
}

// if zip, extract the first file with known extention
(Uint8List, String) _extractIfZip(Uint8List file, String name) {
  if (_fileExtension(name) != "zip") {
    return (file, name);
  }

  final archive = ZipDecoder().decodeBytes(file);

  for (final entry in archive) {
    if (CoreFactory.extensions.contains(_fileExtension(entry.name))) {
      return (entry.content as Uint8List, entry.name);
    }
  }

  throw Exception("No uknown files in the zip: $name");
}
