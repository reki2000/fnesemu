// Dart imports:
import 'dart:typed_data';

// Project imports:
import 'nrom.dart';

// https://www.nesdev.org/wiki/INES_Mapper_003
class MapperCNROM extends MapperNROM {
  late Uint8List _charBank;

  @override
  void init() {
    super.init();
    _charBank = chrRoms[0];
  }

  @override
  void write(int addr, int data) {
    if (addr & 0x8000 == 0x8000) {
      _charBank = chrRoms[data & 0x03];
    }
  }

  @override
  int readVram(int addr) {
    return _charBank[addr & 0x1fff];
  }
}
