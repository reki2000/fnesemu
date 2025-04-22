import 'dart:typed_data';

abstract class Disc {
  static const int sectorSize = 2352; // bytes per sector
  static const int sectorDataSize = 2324; // bytes per sector data
  static Uint8List get empty => Uint8List(sectorDataSize);

  Uint8List read(int sector);
}
