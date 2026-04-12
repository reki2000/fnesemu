import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';

import '../util/debug.dart';
import 'disc.dart';

/*
  1 sector = 930h bytes (2352 bytes)

  000h 0Ch  Sync   (00h,FFh,FFh,FFh,FFh,FFh,FFh,FFh,FFh,FFh,FFh,00h)
  00Ch 4    Header (Minute,Second,Sector,Mode=02h) packed BCD
  010h 4    Sub-Header (File, Channel, Submode OR 20h, Codinginfo)
  014h 4    Copy of Sub-Header
  018h 914h Data (2324 bytes)
  92Ch 4    EDC (checksum across [010h..92Bh]) (or 00000000h if no EDC)
 */

class IsoDisc extends Disc {
  final String path;
  Uint8List data = Uint8List(0);
  static const sync = [
    0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0 // 12 bytes
  ];

  IsoDisc(this.path);

  bool load() {
    try {
      data = File(path).readAsBytesSync();
      debugLog(
          "disc: iso: Loaded disc image from $path. ${data.length.format3} bytes.");
    } catch (e) {
      debugLog("disc: iso: Error on loading disc image from $path. $e");
      return false;
    }
    return true;
  }

  // returns whole sector date without sync
  @override
  Uint8List read(int sector) {
    if (data.isEmpty) {
      if (!load()) {
        return Disc.emptySector; // empty buffer
      }
    }

    sector -= 2 * 75; // skip lead-in

    if (sector < 0 || (sector + 1) * Disc.sectorSize >= data.length) {
      return Disc.emptySector; // empty buffer
    }

    final sectorOffset = sector * Disc.sectorSize;
    final dataOffset = sectorOffset;

    // logReadSector(sector, sectorOffset);

    return data.sublist(dataOffset, dataOffset + Disc.sectorSize);
  }

  @override
  bool get isEmpty => false;

  void logReadSector(int sector, int sectorOffset) {
    final headerOffset = sectorOffset + sync.length;
    final minutes = data[headerOffset];
    final seconds = data[headerOffset + 1];
    final sectorNumber = data[headerOffset + 2];
    final mode = data[headerOffset + 3];
    final file = data[headerOffset + 4];
    final channel = data[headerOffset + 5];
    final submode = data[headerOffset + 6];
    final codinginfo = data[headerOffset + 7];
    debugLog(
        "iso: read sector $sector iso:${sectorOffset.hex32} (${minutes.hex8}:${seconds.hex8}:${sectorNumber.hex8}) mode:$mode file:$file channel:$channel submode:${submode.hex8} codinginfo:${codinginfo.hex8}");
  }
}
