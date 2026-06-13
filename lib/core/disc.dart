import 'dart:typed_data';

import 'package:fnesemu/util/uint8list.dart';

abstract class Disc {
  Uint8List read(int sector);
  int get trackCount;
  int get totalSectors;
  int startLba(int trackNo);
  bool get isEmpty;
  bool isAudio(int trackNo);

  bool isAudioSector(int sector) {
    if (isEmpty) return false;
    for (int trackNo = 1; trackNo <= trackCount; trackNo++) {
      if (sector < startLba(trackNo)) {
        return isAudio(trackNo);
      }
    }
    return false; // out of range
  }

  static const int sectorSize = 2352; // 0x930 = 24bytes x 98frames
  // static const int sectorDataSize = 2324; // bytes per sector data
  static Uint8List emptySector = Uint8List(sectorSize);

  static const sync = [
    0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0 // 12 bytes
  ];

  static String dumpSector(int sector) {
    final (m, s, f) = lbaToMsf(sector);
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    final ff = f.toString().padLeft(2, '0');
    return "$sector ($mm:$ss:$ff)";
  }

  static (int, int, int) lbaToMsf(int lba, {bool addLeadIn = false}) {
    final msf = lba + (addLeadIn ? 150 : 0);
    final m = msf ~/ (60 * 75);
    final s = (msf ~/ 75) % 60;
    final f = msf % 75;
    return (m, s, f);
  }

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
