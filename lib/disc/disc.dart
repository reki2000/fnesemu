import 'dart:typed_data';

import 'package:fnesemu/core/disc.dart' as core_disc;

abstract class Disc extends core_disc.Disc {
  static const int sectorSize = 2352; // bytes per sector
  static const int sectorDataSize = 2324; // bytes per sector data
  static Uint8List emptySector = Uint8List(sectorDataSize);
}
