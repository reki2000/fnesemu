import 'dart:typed_data';

import 'package:fnesemu/core/disc.dart' as core_disc;

abstract class Disc extends core_disc.Disc {
  static const int sectorSize = 2352; // 0x930 = 24bytes x 98frames
  // static const int sectorDataSize = 2324; // bytes per sector data
  static Uint8List emptySector = Uint8List(sectorSize);

  static const sync = [
    0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0 // 12 bytes
  ];
}
