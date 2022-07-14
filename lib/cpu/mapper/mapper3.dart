// Dart imports:
import 'dart:typed_data';

// Project imports:
import 'mapper0.dart';

class Mapper3 extends Mapper0 {
  static final _emptyBank = Uint8List(1024 * 8);
  Uint8List _charBank = _emptyBank;

  @override
  void write(int addr, int data) {
    if (addr & 0x8000 == 0x8000) {
      _charBank = charRoms[data & 0x03];
    }
  }

  @override
  int readVram(int addr) {
    return _charBank[addr & 0x1fff];
  }
}
