import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';

import '../core/disc.dart';
import 'package:fnesemu/util/debug.dart';

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

  IsoDisc(this.path) {
    try {
      data = File(path).readAsBytesSync();
      debugLog(
          "disc: iso: Loaded disc image from $path. ${data.length.format3} bytes.");
    } catch (e) {
      debugLog("disc: iso: Error on loading disc image from $path. $e");
    }
  }

  @override
  int get trackCount => 1;

  @override
  int get totalSectors => data.length ~/ Disc.sectorSize;

  @override
  int startLba(int trackNo) {
    if (trackNo != 1) {
      throw RangeError("disc: iso: invalid track number $trackNo");
    }
    return 0;
  }

  @override
  bool get isEmpty => data.isEmpty;

  @override
  bool isAudio(int trackNo) => false;

  @override
  Uint8List read(int sector) {
    sector -= 2 * 75; // skip lead-in

    if (sector < 0 || (sector + 1) * Disc.sectorSize >= data.length) {
      return Uint8List(0); // error out of range
    }

    final sectorOffset = sector * Disc.sectorSize;
    final dataOffset = sectorOffset;

    // logReadSector(sector, sectorOffset);

    return data.sublist(dataOffset, dataOffset + Disc.sectorSize);
  }

  void logReadSector(int sector, int sectorOffset) {
    final headerOffset = sectorOffset + Disc.sync.length;
    final minutes = data[headerOffset];
    final seconds = data[headerOffset + 1];
    final sectorNumber = data[headerOffset + 2];
    final mode = data[headerOffset + 3];
    final file = data[headerOffset + 4];
    final channel = data[headerOffset + 5];
    final submode = data[headerOffset + 6];
    final codinginfo = data[headerOffset + 7];
    debugLog(
        "iso: read sector $sector iso:${sectorOffset.x8} (${minutes.x2}:${seconds.x2}:${sectorNumber.x2}) "
        "mode:$mode file:$file channel:$channel submode:${submode.x2} codinginfo:${codinginfo.x2}"
        "[${data.sublist(sectorOffset + Disc.sync.length, sectorOffset + Disc.sync.length + 16).map((e) => e.x2).join(" ")}...]");
  }
}
