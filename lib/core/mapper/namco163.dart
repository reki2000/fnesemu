// Dart imports:
import 'dart:typed_data';

// Project imports:
import '../../util.dart';
import 'mapper.dart';
import 'mirror.dart';
import 'sram.dart';

// https://www.nesdev.org/wiki/INES_Mapper_019
class MapperNamco163 extends Mapper with Sram {
  // ppu 12 x 1k banks (0000-1fff, 0x2000-0x2fff)
  // bank
  //   chrRoms.length    : nametable A
  //   chrRoms.length + 1: nametable B
  final _chrBank = List<int>.filled(12, 0);

  // use chrRam at 0x0000, 0x1000
  final _chrRamEnabled = [false, false];
  final _chrRam = Uint8List(1024 * 2);

  // cpu 4 x 8k banks (8000-9fff, a000-bfff, c000-dfff, e000-ffff)
  final _prgBank = [0, 1, 2, 3];
  int _prgBankMask = 0x3f;

  // 8k RAM
  final _ramProtect = [false, false, false, false];

  @override
  int get chrRomSizeK => 1;
  @override
  int get prgRomSizeK => 8;

  @override
  void init() {
    _prgBank[3] = prgRoms.length - 1;
    _prgBankMask = prgRoms.length - 1;

    for (int i = 8; i < 12; i++) {
      _chrBank[i] = chrRoms.length;
    }
    mirror(Mirror.external);
  }

  @override
  void write(int addr, int data) {
    final reg = addr & 0xf800;

    switch (reg) {
      case 0x4800:
        // chip ram write
        break;

      // IRQ related
      case 0x5000:
        _irqCounter = _irqCounter.withLowByte(data);
        holdIrq(false);
        return;
      case 0x5800:
        _irqCounter = _irqCounter.withHighByte(data & 0x7f);
        _irqEnabled = bit7(data);
        holdIrq(false);
        return;

      // ram
      case 0x6000:
      case 0x6800:
      case 0x7000:
      case 0x7800:
        if (!_ramProtect[(addr - 0x6000) >> 11]) {
          ram[addr & 0x1fff] = data;
        }
        return;

      // chr rom select
      case 0x8000:
      case 0x8800:
      case 0x9000:
      case 0x9800:
      case 0xa000:
      case 0xa800:
      case 0xb000:
      case 0xb800:
        final bank = (reg - 0x8000) >> 11; // 00-07

        if (data < 0xe0) {
          _chrBank[bank] = data;
          return;
        }

        // if not chrRam, use last 32 bank
        if (!_chrRamEnabled[bank >> 2]) {
          _chrBank[bank] = chrRoms.length - 0x20 + (data - 0xe0);
        } else {
          _chrBank[bank] = chrRoms.length + (data & 1);
        }
        break;

      // nametable select
      case 0xc000:
      case 0xc800:
      case 0xd000:
      case 0xd800:
        final bank = (reg - 0x8000) >> 11;
        _chrBank[bank] = chrRoms.length + (data & 1);
        break;

      // prg rom bank 0x8000 select
      case 0xe000:
        _prgBank[0] = data & _prgBankMask;
        // _enableSound = bit6(data);
        // _pin22 = !bit7(data);
        break;

      // prg rom bank 0xa000 select
      case 0xe800:
        _prgBank[1] = data & _prgBankMask;
        _chrRamEnabled[0] = !bit6(data);
        _chrRamEnabled[1] = !bit7(data);
        break;

      // prg rom bank 0xc000 select
      case 0xf000:
        _prgBank[2] = data & _prgBankMask;
        // _pin44 = bit7(data);
        break;

      // prg ram write protect
      case 0xf800:
        if (data & 0x40 == 0x40) {
          _ramProtect[0] = bit0(data);
          _ramProtect[1] = bit1(data);
          _ramProtect[2] = bit2(data);
          _ramProtect[3] = bit3(data);
        } else {
          for (int i = 0; i < 4; i++) {
            _ramProtect[i] = true;
          }
        }
        break;
    }
  }

  @override
  int read(int addr) {
    final reg = addr & 0xf800;

    switch (reg) {
      case 0x5000:
        return _irqCounter & 0xff;
      case 0x5800:
        return _irqCounter >> 8;

      // ram
      case 0x6000:
      case 0x6800:
      case 0x7000:
      case 0x7800:
        return ram[addr - 0x6000];
    }

    if (addr >= 0x8000) {
      final bank = ((addr - 0x8000) >> 13);
      final offset = addr & 0x1fff;

      return prgRoms[_prgBank[bank]][offset];
    }

    return 0xff;
  }

  @override
  int readVram(int addr) {
    final bank = addr >> 10;
    final offset = addr & 0x03ff;

    final ramBank = _chrBank[bank] - chrRoms.length;
    if (ramBank >= 0) {
      return _chrRam[offset + (ramBank << 10)];
    } else {
      return chrRoms[_chrBank[bank]][offset];
    }
  }

  @override
  void writeVram(int addr, int data) {
    final bank = addr >> 10;
    final offset = addr & 0x03ff;

    final ramBank = _chrBank[bank] - chrRoms.length;
    if (ramBank >= 0) {
      _chrRam[offset + (ramBank << 10)] = data;
    }
  }

  // IRQ
  int _irqCounter = 0;

  static const _clocksPerTickIrqCounter = 15;
  int _clockDiff = 0;
  int _prevCycle = 0;
  bool _irqEnabled = false;

  @override
  void handleClock(int cycles) {
    _clockDiff += (cycles - _prevCycle);
    _prevCycle = cycles;

    while (_clockDiff >= _clocksPerTickIrqCounter) {
      _clockDiff -= _clocksPerTickIrqCounter;

      if (_irqCounter != 0x7fff) {
        _irqCounter += 1;

        if (_irqCounter == 0x7fff) {
          if (_irqEnabled) {
            holdIrq(true);
          }
        }
      }
    }
  }

  @override
  String dump() {
    final chrBanks = range(0, 12)
        .map((i) => (_chrBank[i] < chrRoms.length)
            ? hex8(_chrBank[i])
            : _chrBank[i] == chrRoms.length
                ? " A"
                : " B")
        .toList()
        .join(" ");

    final prgBanks =
        range(0, 4).map((i) => hex8(_prgBank[i])).toList().join(" ");

    return "rom: "
        "chr: $chrBanks prg: $prgBanks "
        "\n";
  }
}
