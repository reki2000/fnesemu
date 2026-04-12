import 'dart:typed_data';

import 'package:fnesemu/util/uint8list.dart';

abstract class Disc {
  Uint8List read(int sector);
  bool get isEmpty;

  Uint8List loadIso9660File(String path) {
    readSector(i) => read(i + 2 * 75).sublist(0x18); // skip lead-in and sync

    final volumeDescription = readSector(16);
    final rootEntry = volumeDescription.sublist(0x9c, 0x9c + 34);
    final rootLba = rootEntry.getUint32LE(0x02);
    final rootSize = rootEntry.getUint32LE(0x0a);
    final directory = readSector(rootLba);

    for (int i = 0; i < rootSize && i < 0x800;) {
      final entry = directory.sublist(i);
      final nameLen = entry[0x20];
      final name = String.fromCharCodes(entry.sublist(0x21, 0x21 + nameLen));
      final lba = entry.getUint32LE(0x02);
      final size = entry.getUint32LE(0x0a);
      // debugLog("iso9660: found $name lba:$lba size:$size");

      if (name == path) {
        final fileBody = <int>[];
        int currentSector = lba;
        while (fileBody.length < size) {
          final data = readSector(currentSector++);
          if (data.isEmpty) {
            break;
          }
          fileBody.addAll(data);
        }
        return Uint8List.fromList(fileBody.sublist(0, size));
      }

      i += entry[0];
    }

    return Uint8List(0);
  }
}
