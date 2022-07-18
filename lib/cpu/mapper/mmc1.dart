// Dart imports:
import 'dart:typed_data';

// Project imports:
import 'mapper.dart';

// MMC1
// https://www.nesdev.org/wiki/MMC1
class MapperMMC1 extends Mapper {
  int _shiftReg = 0;
  int _counter = 0;

  bool _chrBank4k = false;
  int _prgBankMode = 0;
  int _mirroring = 0;

  final _ram8k =
      List.generate(4, (_) => Uint8List.fromList(List.filled(8 * 1024, 0)));
  bool _ramEnabled = true;
  int _ramBank = 0;

  //final List<Uint8List> _chrRom4K = List.empty(growable: true);
  final _vram4k =
      List.generate(2, (_) => Uint8List.fromList(List.filled(4 * 1024, 0)));

  // ppu 2 x 4k banks (0000-0fff, 1000-1fff)
  final _chrBank = [0, 1];

  // cpu 2 x 16k banks (8000-bfff, c000-ffff)
  final _progBank = [0, 1];

  @override
  void init() {
    // for (final char8k in charRoms) {
    //   for (int i = 0; i < 8 * 1024; i += 4 * 1024) {
    //     _chrRom4K.add(char8k.sublist(i, i + 4 * 1024));
    //   }
    // }
  }

  @override
  void write(int addr, int data) {
    final bank = addr & 0xe000;

    // ram
    if (bank == 0x6000 && _ramEnabled) {
      _ram8k[_ramBank][addr & 0x1fff] = data;
      return;
    }

    // shift register reset
    if (data & 0x80 != 0) {
      _counter = 0;
      _shiftReg = 0;
      _progBank[1] = programRoms.length - 1;
      return;
    }

    // shift register write
    _shiftReg <<= 1;
    _shiftReg |= data & 0x01;
    _counter++;

    // the fifth write to control
    if (_counter == 5) {
      switch (bank) {
        case 0x8000:
          _chrBank4k = _shiftReg & 0x10 != 0;
          _prgBankMode = (_shiftReg >> 2) & 0x03;
          switch (_prgBankMode) {
            case 2:
              _progBank[0] = 0;
              break;
            case 3:
              _progBank[1] = programRoms.length - 1;
              break;
          }
          _mirroring = _shiftReg & 0x03;
          break;
        case 0xa000:
          if (_chrBank4k) {
            _chrBank[0] = _shiftReg & 0x01;
          }
          _ramBank = (_shiftReg >> 1) & 0x03;
          break;
        case 0xc000:
          if (_chrBank4k) {
            _chrBank[1] = _shiftReg & 0x01;
          }
          _ramBank = (_shiftReg >> 1) & 0x03;
          break;
        case 0xe000:
          _ramEnabled = _shiftReg & 0x10 == 0;
          switch (_prgBankMode) {
            case 0:
            case 1:
              _progBank[0] = _shiftReg & 0x0e;
              _progBank[1] = (_shiftReg & 0x0e) + 1;
              break;
            case 2:
              _progBank[1] = _shiftReg & 0x0f;
              break;
            case 3:
              _progBank[0] = _shiftReg & 0x0f;
              break;
          }
          break;
      }
      _shiftReg = 0;
      _counter = 0;
    }
  }

  @override
  int read(int addr) {
    if ((addr & 0xe000) == 0x6000) {
      return _ramEnabled ? _ram8k[_ramBank][addr & 0x1fff] : 0xff;
    }

    final bank = addr >> 14;
    final offset = addr & 0x3fff;

    switch (bank) {
      case 2:
        return programRoms[_progBank[0]][offset];
      case 3:
        return programRoms[_progBank[1]][offset];
    }
    return 0xff;
  }

  @override
  int readVram(int addr) {
    final bank = (addr >> 12) & 0x1;
    final offset = addr & 0x0fff;
    return _vram4k[_chrBank[bank]][offset];
  }

  @override
  void writeVram(int addr, int data) {
    final bank = (addr >> 12) & 0x1;
    final offset = addr & 0x0fff;
    _vram4k[_chrBank[bank]][offset] = data & 0xff;
  }
}
