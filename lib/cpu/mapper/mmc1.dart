// Dart imports:
import 'dart:developer';
import 'dart:typed_data';

// Project imports:
import '../util.dart';
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

  final _vram4k =
      List.generate(2, (_) => Uint8List.fromList(List.filled(4 * 1024, 0)));

  // ppu 2 x 4k banks (0000-0fff, 1000-1fff)
  final _chrBank = [0, 1];

  // cpu 2 x 16k banks (8000-bfff, c000-ffff)
  final _prgBank = [0, 1];
  int _prgBank0 = 0;

  @override
  void init() {
    // for (final char8k in charRoms) {
    //   for (int i = 0; i < 8 * 1024; i += 4 * 1024) {
    //     _chrRom4K.add(char8k.sublist(i, i + 4 * 1024));
    //   }
    // }
    _prgBank0 = 0;
    _prgBank[0] = _prgBank0;
    _prgBank[1] = programRoms.length - 1;
  }

  @override
  void write(int addr, int data) {
    final bank = addr & 0xe000;

    // ram
    if (bank == 0x6000) {
      if (_ramEnabled) {
        _ram8k[_ramBank][addr & 0x1fff] = data;
      }
      return;
    }

    // shift register reset
    if (bit7(data)) {
      _counter = 0;
      _shiftReg = 0;
      _prgBank[1] = programRoms.length - 1;
      return;
    }

    // shift register write
    _shiftReg >>= 1;
    _shiftReg |= ((data & 0x01) << 4);
    _counter++;

    // the fifth write to control
    if (_counter == 5) {
      switch (bank) {
        case 0x8000:
          _chrBank4k = bit4(_shiftReg);
          if (!_chrBank4k) {
            _chrBank[0] = 0;
            _chrBank[1] = 1;
          }

          _prgBankMode = (_shiftReg >> 2) & 0x03;
          _setPrgBank();

          _mirroring = _shiftReg & 0x03;
          switch (_mirroring) {
            case 2:
              mirrorVertical(true);
              break;
            case 3:
              mirrorVertical(false);
              break;
          }
          break;

        case 0xa000:
          if (_chrBank4k) {
            _chrBank[0] = _shiftReg & 0x01;
          }

          // S[OUX]ROM supports RAM
          _ramBank = (_shiftReg >> 2) & 0x03;

          // 256KB bank
          if (bit4(_shiftReg) && programRoms.length == 32) {
            _prgBank0 |= 0x10;
          } else {
            _prgBank0 &= ~0x10;
          }
          _setPrgBank();
          break;

        case 0xc000:
          if (_chrBank4k) {
            _chrBank[1] = _shiftReg & 0x01;

            // S[OUX]ROM supports RAM
            _ramBank = (_shiftReg >> 2) & 0x03;

            // 256KB bank
            if (bit4(_shiftReg) && programRoms.length == 32) {
              _prgBank0 |= 0x10;
            } else {
              _prgBank0 &= ~0x10;
            }
            _setPrgBank();
          }
          break;

        case 0xe000:
          _ramEnabled = !bit4(_shiftReg);

          switch (_prgBankMode) {
            case 0:
            case 1:
              _prgBank0 = _shiftReg & 0x0e;
              _setPrgBank();
              break;
            case 2:
            case 3:
              _prgBank0 = _shiftReg & 0x0f;
              _setPrgBank();
              break;
          }
          break;
      }

      _shiftReg = 0;
      _counter = 0;
    }
  }

  void _setPrgBank() {
    switch (_prgBankMode) {
      case 0:
      case 1:
        _prgBank[0] = _prgBank0;
        _prgBank[1] = _prgBank0 + 1;
        break;
      case 2:
        _prgBank[0] = 0;
        _prgBank[1] = _prgBank0;
        break;
      case 3:
        _prgBank[0] = _prgBank0;
        _prgBank[1] = programRoms.length - 1;
        break;
    }
  }

  @override
  int read(int addr) {
    final bank = addr & 0xe000;
    final offset = addr & 0x3fff;

    switch (bank) {
      case 0x6000:
        return _ramEnabled ? _ram8k[_ramBank][addr & 0x1fff] : 0xff;

      case 0x8000:
      case 0xa000:
        return programRoms[_prgBank[0]][offset];

      case 0xc000:
      case 0xe000:
        return programRoms[_prgBank[1]][offset];
    }

    log("mmc1: invalid addr: ${hex16(addr)}");
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

  @override
  String dump() {
    final range0_1 = range(0, 2);

    final chrBanks = range0_1.map((i) => hex8(_chrBank[i])).toList().join(" ");
    final prgBanks = range0_1.map((i) => hex8(_prgBank[i])).toList().join(" ");
    final ramBank = hex8(_ramBank);

    return "rom: "
        "chr:${_chrBank4k ? '4k' : '8k'} $chrBanks prg:mode$_prgBankMode $prgBanks ram:${_ramEnabled ? '*' : '-'} $ramBank"
        "\n";
  }
}
