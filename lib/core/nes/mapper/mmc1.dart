// Dart imports:
import 'dart:developer';
import 'dart:typed_data';

// Project imports:
import 'package:fnesemu/util/int.dart';
import 'package:fnesemu/util/uint8list.dart';

import 'mapper.dart';
import 'mirror.dart';

// MMC1
// https://www.nesdev.org/wiki/MMC1
class MapperMMC1 extends Mapper {
  late int _shiftReg;
  late int _counter;

  // ram on 6000-7fff, 8k x 4 banks
  late bool _ramEnabled = true;
  late int _ramBank;

  late bool _chrBank4k;

  // chr bank registers written to a000 and c000
  final _chrReg = [0, 0];

  // ppu 2 x 4k banks (0000-0fff, 1000-1fff)
  final _chrBank = [0, 0];

  // used when the cartridge has no chr rom
  final _vram4k = Uint8ListEx.ofEmptyList(2, 4 * 1024);

  bool get _hasChrRam => chrRoms.isEmpty;

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
  void setRom(Uint8List chrRom, Uint8List prgRom) {
    loadRom(chrRom, 4, prgRom, 16);
  }

  @override
  void init() {
    _shiftReg = 0;
    _counter = 0;

    _ramBank = 0;
    _ramEnabled = true;

    _chrBank4k = false;
    _chrReg[0] = 0;
    _chrReg[1] = 0;
    _setChrBank();

    _prgBankMode = 3;
    _prgBank0 = 0;
    _prgBank512 = false;
    _setPrgBank();
  }

  @override
  Uint8List defaultSram() {
    return Uint8List(4 * 8 * 1024);
  }

  @override
  void write(int addr, int data) {
    final bank = addr & 0xe000;

    // ram
    if (bank == 0x6000) {
      if (_ramEnabled) {
        writeSram(addr & 0x1fff | _ramBank.shl13, data);
      } else {
        log("mmc1: write to disabled ram: ${addr.x4} ${data.x2}");
      }
      return;
    }

    // shift register reset, also sets prg bank mode 3
    if (data.bit7) {
      _counter = 0;
      _shiftReg = 0;
      _prgBankMode = 3;
      _setPrgBank();
      return;
    }

    // shift register write
    _shiftReg >>= 1;
    _shiftReg |= (data & 0x01).shl4;
    _counter++;

    // the fifth write to control
    if (_counter == 5) {
      switch (bank) {
        case 0x8000:
          _chrBank4k = _shiftReg.bit4;
          _setChrBank();

          _prgBankMode = _shiftReg.shr2 & 0x03;
          _setPrgBank();

          mirror(_mirrors[_shiftReg & 0x03]);
          break;

        case 0xa000:
          _chrReg[0] = _shiftReg;
          _setChrBank();
          _setOuterBank(_shiftReg);
          break;

        case 0xc000:
          _chrReg[1] = _shiftReg;
          _setChrBank();
          if (_chrBank4k) {
            _setOuterBank(_shiftReg);
          }
          break;

        case 0xe000:
          _ramEnabled = !_shiftReg.bit4;

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
      //log("mmc1: ${addr.x4} <= ${_shiftReg.x2} ${dump()}");

      _shiftReg = 0;
      _counter = 0;
    }
  }

  // S[OUX]ROM (chr ram boards) use the upper chr bank bits for prg/ram banks
  void _setOuterBank(int val) {
    if (!_hasChrRam) {
      return;
    }

    _ramBank = val.shr2 & 0x03;

    // 512k ROM A18 select
    _prgBank512 = val.bit4 && prgRoms.length == 32;
    _setPrgBank();
  }

  void _setChrBank() {
    if (_hasChrRam) {
      // 8k chr ram
      _chrBank[0] = _chrBank4k ? _chrReg[0] & 0x01 : 0;
      _chrBank[1] = _chrBank4k ? _chrReg[1] & 0x01 : 1;
      return;
    }

    final mask = chrRoms.length - 1;
    if (_chrBank4k) {
      _chrBank[0] = _chrReg[0] & mask;
      _chrBank[1] = _chrReg[1] & mask;
    } else {
      _chrBank[0] = (_chrReg[0] & 0x1e) & mask;
      _chrBank[1] = (_chrReg[0] | 0x01) & mask;
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

    _prgBank[0] %= prgRoms.length;
    _prgBank[1] %= prgRoms.length;
  }

  @override
  int read(int addr) {
    final bank = addr & 0xe000;
    final offset = addr & 0x3fff;

    switch (bank) {
      case 0x6000:
        return _ramEnabled ? readSram(addr & 0x1fff | _ramBank.shl13) : 0xff;

      case 0x8000:
      case 0xa000:
        return prgRoms[_prgBank[0]][offset];

      case 0xc000:
      case 0xe000:
        return prgRoms[_prgBank[1]][offset];
    }

    log("mmc1: invalid addr: ${addr.x4}");
    return 0xff;
  }

  @override
  int readVram(int addr) {
    final bank = addr.shr12 & 0x1;
    final offset = addr & 0x0fff;
    return _hasChrRam
        ? _vram4k[_chrBank[bank]][offset]
        : chrRoms[_chrBank[bank]][offset];
  }

  @override
  void writeVram(int addr, int data) {
    if (!_hasChrRam) {
      return;
    }

    final bank = addr.shr12 & 0x1;
    final offset = addr & 0x0fff;
    _vram4k[_chrBank[bank]][offset] = data & 0xff;
  }

  @override
  String dump() {
    final range0_1 = range(0, 2);

    final chrBanks = range0_1.map((i) => _chrBank[i].x2).toList().join(" ");
    final prgBanks = range0_1.map((i) => _prgBank[i].x2).toList().join(" ");
    final ramBank = _ramBank.x2;

    return "rom: "
        "chr:${_chrBank4k ? '4k' : '8k'} $chrBanks prg:mode$_prgBankMode $prgBanks ram:${_ramEnabled ? '*' : '-'}$ramBank"
        "\n";
  }
}
