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

  /// true when the image holds only 2048-byte user data per sector (cooked iso)
  bool cooked = false;

  static const cookedSectorSize = 2048;

  IsoDisc(this.path) {
    try {
      data = File(path).readAsBytesSync();
      cooked = _isCooked(data);
      debugLog(
          "disc: iso: Loaded disc image from $path. ${data.length.format3} bytes${cooked ? " (2048 bytes/sector)" : ""}.");
    } catch (e) {
      debugLog("disc: iso: Error on loading disc image from $path. $e");
    }
  }

  // raw images start with the sync pattern, cooked ones have "CD001" at sector 16
  static bool _isCooked(Uint8List data) {
    for (int i = 0; i < Disc.sync.length; i++) {
      if (i >= data.length || data[i] != Disc.sync[i]) {
        const pvd = 16 * cookedSectorSize + 1;
        return data.length > pvd + 5 &&
            String.fromCharCodes(data.sublist(pvd, pvd + 5)) == "CD001";
      }
    }
    return false;
  }

  // builds a raw mode 1 sector from 2048 bytes of user data
  Uint8List _cookedToRaw(int lba) {
    final raw = Uint8List(Disc.sectorSize);
    raw.setRange(0, Disc.sync.length, Disc.sync);
    final (m, s, f) = Disc.lbaToMsf(lba, addLeadIn: true);
    int bcd(int v) => (v ~/ 10) << 4 | v % 10;
    raw[12] = bcd(m);
    raw[13] = bcd(s);
    raw[14] = bcd(f);
    raw[15] = 1;
    final offset = lba * cookedSectorSize;
    raw.setRange(16, 16 + cookedSectorSize,
        Uint8List.sublistView(data, offset, offset + cookedSectorSize));
    return raw;
  }

  @override
  int get trackCount => 1;

  @override
  int get totalSectors =>
      data.length ~/ (cooked ? cookedSectorSize : Disc.sectorSize);

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

    if (cooked) {
      if (sector < 0 || sector >= totalSectors) {
        return Uint8List(0);
      }
      return _cookedToRaw(sector);
    }

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
