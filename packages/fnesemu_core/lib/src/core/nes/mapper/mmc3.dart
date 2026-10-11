import 'dart:developer';
import 'dart:typed_data';

import '../../../util/int.dart';

import 'mapper.dart';
import 'mirror.dart';

// https://www.nesdev.org/wiki/MMC3
class MapperMMC3 extends Mapper {
  // bank register
  int _r = 0;

  // bit12 of previous char rom access address for IRQ detection
  int _a12 = 0;

  // IRQ related counters, flags etc.
  int _irqLatch = 0;
  int _irqCounter = 0;
  bool _irqReload = false;
  bool _irqEnabled = false;

  // ram: enabled by default, as many games use it without setting a001
  bool _ramEnabled = true;
  bool _ramWriteEnabled = true;

  int _chrBankMask = 0;
  int _prgBankMask = 0;

  // ppu 2 x 4k banks (0000-0fff, 1000-1fff)
  // each item points one of _chrBankR2_5 or _chrBankR0_1
  //
  // each bank has 4 x 1k banks (000-3ff, 400-7ff, 800-bff, c00-fff)
  final List<List<int>> _chrBank = [[], []];

  final _chrBankR2_5 = List.filled(4, 0);
  final _chrBankR0_1 = List.filled(4, 0);

  // cpu 4 x 8k banks (8000-9fff, a000-bfff, c000-dfff, e000-ffff)
  // each item points one of _progBank0, _progBank2ndLast, _progBankA0
  final List<List<int>> _prgBank = List.filled(4, []);

  final _prgBank0 = [0]; // for 8000-9fff or c000-dfff
  final _prgBank2ndLast = [0]; // for 8000-9fff or c000-dfff
  final _prgBankA000 = [0]; // for a000-bfff

  @override
  int get chrRomSizeK => 1;
  @override
  int get prgRomSizeK => 8;

  @override
  void init() {
    if (chrRoms.isEmpty) {
      // TNROM: chr ram 1k x 8
      chrRoms.addAll(List.generate(8, (i) => Uint8List(1024)));
    }
    _chrBank[0] = _chrBankR2_5;
    _chrBank[1] = _chrBankR0_1;

    _irqLatch = 0;
    _irqCounter = 0;
    _irqReload = false;
    _irqEnabled = false;
    _ramEnabled = true;
    _ramWriteEnabled = true;

    _chrBankMask = chrRoms.length - 1;
    if (chrRoms.length & _chrBankMask != 0) {
      log("invalid chr rom size: ${_chrBank.length}k");
      return;
    }

    // resize prg roms from 16k to 8k
    _prgBankMask = prgRoms.length - 1;
    if (_prgBankMask & prgRoms.length != 0) {
      log("invalid prg rom size: ${prgRoms.length}k");
      return;
    }

    _prgBank2ndLast[0] = prgRoms.length - 2;
    _prgBank[0] = _prgBank0; // 0x8000-0x9fff
    _prgBank[1] = _prgBankA000; // 0xa000-0xbfff
    _prgBank[2] = _prgBank2ndLast; // 0xc000-0xdfff
    _prgBank[3] = [prgRoms.length - 1]; // 0xe000-0xffff
  }

  @override
  void write(int addr, int data) {
    final reg = addr & 0xe000;
    final isOdd = addr.bit0;

    switch (reg) {
      case 0x6000:
        if (_ramEnabled && _ramWriteEnabled) {
          writeSram(addr.mask13, data);
        }
        break;

      case 0x8000:
        if (isOdd) {
          switch (_r) {
            case 0:
              final bank = (data & _chrBankMask) & 0xfe;
              _chrBankR0_1[0] = bank;
              _chrBankR0_1[1] = bank + 1;
              break;
            case 1:
              final bank = (data & _chrBankMask) & 0xfe;
              _chrBankR0_1[2] = bank;
              _chrBankR0_1[3] = bank + 1;
              break;
            case 2:
            case 3:
            case 4:
            case 5:
              final bank = data & _chrBankMask;
              _chrBankR2_5[_r - 2] = bank;
              break;
            case 6:
              _prgBank0[0] = data & _prgBankMask;
              break;
            case 7:
              _prgBankA000[0] = data & _prgBankMask;
              break;
          }
        } else {
          // chr A12 Inversion
          if (data.bit7) {
            _chrBank[0] = _chrBankR2_5;
            _chrBank[1] = _chrBankR0_1;
          } else {
            _chrBank[0] = _chrBankR0_1;
            _chrBank[1] = _chrBankR2_5;
          }

          // progRom BankMode 0
          if (!data.bit6) {
            _prgBank[0] = _prgBank0;
            _prgBank[2] = _prgBank2ndLast;
          } else {
            _prgBank[0] = _prgBank2ndLast;
            _prgBank[2] = _prgBank0;
          }

          _r = data.mask3;
        }
        break;

      case 0xa000:
        if (isOdd) {
          _ramEnabled = data.bit7;
          _ramWriteEnabled = !data.bit6;
        } else {
          mirror(data.bit0 ? Mirror.horizontal : Mirror.vertical);
        }
        break;

      case 0xc000:
        if (isOdd) {
          _irqReload = true;
        } else {
          _irqLatch = data;
        }
        break;

      case 0xe000:
        _irqEnabled = isOdd;
        if (!_irqEnabled) {
          holdIrq(false); // acknowledge
        }
        break;
    }
  }

  @override
  int read(int addr) {
    final bank = addr.shr13.mask2;
    final offset = addr.mask13;

    if ((addr & 0xe000) == 0x6000) {
      return _ramEnabled ? readSram(offset) : 0xff;
    }

    return prgRoms[_prgBank[bank][0]][offset];
  }

  @override
  int readVram(int addr) {
    // a12 edge detection for IRQ
    final a12 = addr & 0x1000;
    if (a12 != 0 && _a12 == 0) {
      _tickIrq();
    }
    _a12 = a12;

    final bank = addr.shr10;
    final offset = addr.mask10;

    return chrRoms[_chrBank[bank.shr2][bank.mask2]][offset];
  }

  @override
  int peekVram(int addr, {bool sprite = false}) {
    final bank = addr.shr10;
    return chrRoms[_chrBank[bank.shr2][bank.mask2]][addr.mask10];
  }

  @override
  void writeVram(int addr, int data) {
    final bank = addr.shr10;
    final offset = addr.mask10;

    chrRoms[_chrBank[bank.shr2][bank.mask2]][offset] = data;
  }

  void _tickIrq() {
    if (_irqReload || _irqCounter == 0) {
      _irqCounter = _irqLatch;
      _irqReload = false;
    } else {
      _irqCounter--;
    }

    if (_irqCounter == 0 && _irqEnabled) {
      holdIrq(true);
    }
  }

  @override
  String dump() {
    final range0_3 = range(0, 4);

    final chrBanks0 = range0_3.map((i) => _chrBank[0][i].x2).toList().join(" ");
    final chrBanks1 = range0_3.map((i) => _chrBank[1][i].x2).toList().join(" ");

    final prgBanks = range0_3.map((i) => _prgBank[i][0].x2).toList().join(" ");

    return "rom: irq:${_irqEnabled ? '*' : '-'} "
        "@${_irqCounter.d3z}"
        "/${_irqLatch.d3z} "
        "chr: $chrBanks0 $chrBanks1 prg: $prgBanks "
        "\n";
  }
}

// TxSROM (iNES mapper 118): MMC3 with the nametable chosen by bit 7 of the
// chr bank registers instead of the mirroring register.
// https://www.nesdev.org/wiki/INES_Mapper_118
class MapperTxsrom extends MapperMMC3 {
  // bit 7 written to each of the chr registers R0-R5
  final _ntBit = List<bool>.filled(6, false);
  bool _chrInverted = false;
  final _ciram = Uint8List(0x800);

  @override
  void init() {
    super.init();
    _ntBit.fillRange(0, 6, false);
    _chrInverted = false;
    mirror(Mirror.external);
  }

  @override
  void write(int addr, int data) {
    final reg = addr & 0xe000;
    final isOdd = addr.bit0;

    if (reg == 0xa000 && !isOdd) {
      return; // mirroring is controlled by the chr registers
    }
    if (reg == 0x8000) {
      if (isOdd) {
        if (_r < 6) {
          _ntBit[_r] = data.bit7;
        }
      } else {
        _chrInverted = data.bit7;
      }
    }
    super.write(addr, data);
  }

  // the nametable n (0-3) follows the register of the 1k chr bank at n * 0x400
  bool _page(int addr) {
    final n = addr.shr10.mask2;
    if (_chrInverted) {
      return _ntBit[2 + n]; // R2-R5 at 0000-0fff
    }
    return _ntBit[n.shr1]; // R0 (0000-07ff), R1 (0800-0fff)
  }

  @override
  int readVram(int addr) {
    if (addr < 0x2000) {
      return super.readVram(addr);
    }
    return _ciram[(_page(addr) ? 0x400 : 0) + addr.mask10];
  }

  @override
  int peekVram(int addr, {bool sprite = false}) => addr < 0x2000
      ? super.peekVram(addr, sprite: sprite)
      : _ciram[(_page(addr) ? 0x400 : 0) + addr.mask10];

  @override
  void writeVram(int addr, int data) {
    if (addr < 0x2000) {
      super.writeVram(addr, data);
      return;
    }
    _ciram[(_page(addr) ? 0x400 : 0) + addr.mask10] = data;
  }
}
