// Dart imports:
import 'dart:developer';
import 'dart:typed_data';

// Project imports:
import '../../util.dart';
import 'mapper.dart';
import 'mirror.dart';

// MMC1
// https://www.nesdev.org/wiki/MMC1
class MapperMMC1 extends Mapper {
  late int _shiftReg;
  late int _counter;

  // ram on 6000-7fff, 8k x 4 banks
  final _ram8k = List.generate(4, (_) => Uint8List(8 * 1024));
  late bool _ramEnabled = true;
  late int _ramBank;

  late bool _chrBank4k;

  // ppu 2 x 4k banks (0000-0fff, 1000-1fff)
  final _chrBank = [0, 0];

  final _vram4k = List.generate(2, (_) => Uint8List(4 * 1024));

  // program rom bank mode: 0-3
  late int _prgBankMode;
  late bool _prgBank512;

  // cpu 2 x 16k banks (8000-bfff, c000-ffff)
  final _prgBank = [0, 0];
  late int _prgBank0;

  static final _mirrors = [
    Mirror.oneScreenLow,
    Mirror.oneScreenHigh,
    Mirror.vertical,
    Mirror.horizontal,
  ];

  @override
  void init() {
    _shiftReg = 0;
    _counter = 0;

    _ramBank = 0;
    _ramEnabled = true;

    _chrBank4k = false;
    _chrBank[0] = 0;
    _chrBank[1] = 1;

    _prgBankMode = 3;
    _prgBank0 = 0;
    _prgBank512 = false;
    _setPrgBank();
  }

  @override
  void write(int addr, int data) {
    final bank = addr & 0xe000;

    // ram
    if (bank == 0x6000) {
      if (_ramEnabled) {
        _ram8k[_ramBank][addr & 0x1fff] = data;
      } else {
        log("mmc1: write to disabled ram: ${hex16(addr)} ${hex8(data)}");
      }
      return;
    }

    // shift register reset
    if (bit7(data)) {
      _counter = 0;
      _shiftReg = 0;
      _prgBank[1] = prgRoms.length - 1;
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

          mirror(_mirrors[_shiftReg & 0x03]);
          break;

        case 0xa000:
          if (_chrBank4k) {
            _chrBank[0] = _shiftReg & 0x01;
          }

          // S[OUX]ROM supports RAM
          _ramBank = (_shiftReg >> 2) & 0x03;

          // 512k ROM A18 select
          _prgBank512 = bit4(_shiftReg) && prgRoms.length == 32;
          _setPrgBank();
          break;

        case 0xc000:
          if (_chrBank4k) {
            _chrBank[1] = _shiftReg & 0x01;

            // S[OUX]ROM supports RAM
            _ramBank = (_shiftReg >> 2) & 0x03;

            // 512k ROM A18 select
            _prgBank512 = bit4(_shiftReg) && prgRoms.length == 32;
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
      //log("mmc1: ${hex16(addr)} <= ${hex8(_shiftReg)} ${dump()}");

      _shiftReg = 0;
      _counter = 0;
    }
  }

  void _setPrgBank() {
    final a18 = _prgBank512 ? 0x10 : 0;
    switch (_prgBankMode) {
      case 0:
      case 1:
        _prgBank[0] = _prgBank0 | a18;
        _prgBank[1] = (_prgBank0 + 1) | a18;
        break;
      case 2:
        _prgBank[0] = 0 | a18;
        _prgBank[1] = _prgBank0 | a18;
        break;
      case 3:
        _prgBank[0] = _prgBank0 | a18;
        _prgBank[1] = (prgRoms.length - 1) & 0x0f | a18;
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
        return prgRoms[_prgBank[0]][offset];

      case 0xc000:
      case 0xe000:
        return prgRoms[_prgBank[1]][offset];
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
        "chr:${_chrBank4k ? '4k' : '8k'} $chrBanks prg:mode$_prgBankMode $prgBanks ram:${_ramEnabled ? '*' : '-'}$ramBank"
        "\n";
  }
}
