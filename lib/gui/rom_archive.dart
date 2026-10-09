import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fnesemu_core/core/core_api.dart';

/// the ROM in the file [name]: the first entry of a zip archive which a core
/// recognizes, or the file itself
(Uint8List, String) unpackRom(Uint8List bytes, String name) {
  if (!name.toLowerCase().endsWith('.zip')) return (bytes, name);
  for (final entry in ZipDecoder().decodeBytes(bytes)) {
    if (!entry.isFile) continue;
    final data = Uint8List.fromList(entry.content as List<int>);
    if (CoreFactory.findRom(entry.name, data) != null) {
      return (data, entry.name);
    }
  }
  throw FormatException('No supported ROM in archive: $name');
}
