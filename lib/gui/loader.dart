part of 'app.dart';

String _fileExtension(String fileName) =>
    fileName.substring(fileName.lastIndexOf(".") + 1);

Future<(Uint8List, String)> _pickFile({String name = ""}) async {
  if (name == "") {
    final picked = await FilePicker.platform.pickFiles(withData: true);
    if (picked != null) {
      return (picked.files.first.bytes!, picked.files.first.name);
    }
  } else {
    return (
      (await rootBundle.load('assets/roms/$name')).buffer.asUint8List(),
      name
    );
  }

  throw Exception("file not found: $name");
}

// if zip, extract the first file with known extention
(Uint8List, String) _extractIfZip(Uint8List file, String name) {
  if (_fileExtension(name) != "zip") {
    return (file, name);
  }

  final archive = ZipDecoder().decodeBytes(file);

  for (final entry in archive) {
    if (["nes", "pce", "md", "gen"].contains(_fileExtension(entry.name))) {
      return (entry.content as Uint8List, entry.name);
    }
  }

  throw Exception("No uknown files in the zip: $name");
}
