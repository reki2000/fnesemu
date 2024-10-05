// Dart imports:
import 'dart:typed_data';

// Project imports:
import 'nrom.dart';

// https://www.nesdev.org/wiki/UxROM
class MapperUxROM extends MapperNROM {
  int _progBank = 0;

  final Uint8List _vram = Uint8List(1024 * 8);

  @override
  void write(int addr, int data) {
    if (addr & 0x8000 == 0x8000) {
      _progBank = data & 0x0f;
    }
  }

  @override
  int read(int addr) {
    final bank = addr & 0xc000;
    final offset = addr & 0x3fff;
    if (bank == 0x8000) {
      return prgRoms[_progBank][offset];
    } else if (bank == 0xc000) {
      return prgRoms[prgRoms.length - 1][offset];
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
