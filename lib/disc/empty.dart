import 'dart:typed_data';

import '../core/disc.dart';

class EmptyDisc extends Disc {
  @override
  Uint8List read(int sector) => Disc.emptySector;
  @override
  bool get isEmpty => true;

  @override
  int get trackCount => 0;

  @override
  int get totalSectors => 0;

  @override
  int startLba(int trackNo) {
    throw RangeError("disc: empty: no tracks available");
  }

  @override
  bool isAudio(int trackNo) => false;
}
