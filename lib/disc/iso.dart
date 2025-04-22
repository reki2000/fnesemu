import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';

import '../util/debug.dart';
import 'disc.dart';

class IsoDisc extends Disc {
  final String path;
  Uint8List data = Uint8List(0);

  IsoDisc(this.path);

  bool load() {
    try {
      data = File(path).readAsBytesSync();
      debugLog("Loading disc image from $path. ${data.length.format3} bytes.");
    } catch (e) {
      debugLog("Error on loading disc image from $path. $e");
      return false;
    }
    return true;
  }

  @override
  Uint8List read(int sector) {
    if (data.isEmpty) {
      if (!load()) {
        return Disc.empty; // empty buffer
      }
    }

    sector -= 2 * 75; // skip lead-in

    if (sector < 0 || (sector + 1) * Disc.sectorSize >= data.length) {
      return Disc.empty; // empty buffer
    }

    return data.sublist(sector * Disc.sectorSize + 0x18,
        sector * Disc.sectorSize + 0x18 + Disc.sectorDataSize);
  }
}
