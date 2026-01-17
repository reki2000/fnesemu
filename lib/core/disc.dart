import 'dart:typed_data';

abstract class Disc {
  Uint8List read(int sector);
  bool get isEmpty;
}
