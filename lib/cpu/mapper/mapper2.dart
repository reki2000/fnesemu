// Dart imports:
import 'dart:typed_data';

// Project imports:
import 'mapper0.dart';

class Mapper2 extends Mapper0 {
  static final _emptyBank = Uint8List(1024 * 16);
  Uint8List _progBank = _emptyBank;
  final Uint8List _vram = Uint8List(1024 * 8);

  @override
  void write(int addr, int data) {
    if (addr & 0x8000 == 0x8000) {
      _progBank = programRoms[data & 0x0f];
    }
  }

  @override
  int read(int addr) {
    final bank = addr & 0xc000;
    final offset = addr & 0x3fff;
    if (bank == 0x8000) {
      return _progBank[offset];
    } else if (bank == 0xc000) {
      return programRoms[programRoms.length - 1][offset];
    }

    return 0xff;
  }

  @override
  int readVram(int addr) {
    return _vram[addr & 0x1fff];
  }

  @override
  void writeVram(int addr, int data) {
    _vram[addr & 0x1fff] = data & 0xff;
  }
}
