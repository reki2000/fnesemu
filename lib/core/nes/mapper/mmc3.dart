// Dart imports:
import 'dart:developer';
import 'dart:typed_data';

// Project imports:
import '../../../util/util.dart';
import 'mapper.dart';
import 'mirror.dart';
import 'sram.dart';

// https://www.nesdev.org/wiki/MMC3
class MapperMMC3 extends Mapper with Sram {
  // bank register
  int _r = 0;

  // bit12 of previous char rom access address for IRQ detection
  int _a12 = 0;

  // IRQ related counters, flags etc.
  int _irqLatch = 0;
  int _irqCounter = 0;
  bool _irqReload = false;
  bool _irqEnabled = false;

  // ram
  bool _ramEnabled = false;
  bool _ramWriteEnabled = false;

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
    final isOdd = bit0(addr);

    switch (reg) {
      case 0x6000:
        if (_ramEnabled && _ramWriteEnabled) {
          ram[addr & 0x1fff] = data;
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
          if (bit7(data)) {
            _chrBank[0] = _chrBankR2_5;
            _chrBank[1] = _chrBankR0_1;
          } else {
            _chrBank[0] = _chrBankR0_1;
            _chrBank[1] = _chrBankR2_5;
          }

          // progRom BankMode 0
          if (!bit6(data)) {
            _prgBank[0] = _prgBank0;
            _prgBank[2] = _prgBank2ndLast;
          } else {
            _prgBank[0] = _prgBank2ndLast;
            _prgBank[2] = _prgBank0;
          }

          _r = data & 0x07;
        }
        break;

      case 0xa000:
        if (isOdd) {
          _ramEnabled = bit7(data);
          _ramWriteEnabled = !bit6(data);
        } else {
          mirror(bit0(data) ? Mirror.horizontal : Mirror.vertical);
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
        break;
    }
  }

  @override
  int read(int addr) {
    final bank = (addr >> 13) & 0x03;
    final offset = addr & 0x1fff;

    if ((addr & 0xe000) == 0x6000) {
      return _ramEnabled ? ram[offset] : 0xff;
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

    final bank = addr >> 10;
    final offset = addr & 0x03ff;

    return chrRoms[_chrBank[bank >> 2][bank & 0x03]][offset];
  }

  @override
  void writeVram(int addr, int data) {
    final bank = addr >> 10;
    final offset = addr & 0x03ff;

    chrRoms[_chrBank[bank >> 2][bank & 0x03]][offset] = data;
  }

  void _tickIrq() {
    if (_irqCounter == 0 && _irqEnabled && _irqLatch != 0) {
      holdIrq(true);
    }

    if (_irqReload || _irqCounter == 0) {
      _irqCounter = _irqLatch;
      _irqReload = false;
    } else {
      _irqCounter--;
    }
  }

  @override
  String dump() {
    final range0_3 = range(0, 4);

    final chrBanks0 =
        range0_3.map((i) => hex8(_chrBank[0][i])).toList().join(" ");
    final chrBanks1 =
        range0_3.map((i) => hex8(_chrBank[1][i])).toList().join(" ");

    final prgBanks =
        range0_3.map((i) => hex8(_prgBank[i][0])).toList().join(" ");

    return "rom: irq:${_irqEnabled ? '*' : '-'} "
        "@${_irqCounter.toRadixString(10).padLeft(3, "0")}"
        "/${_irqLatch.toRadixString(10).padLeft(3, "0")} "
        "chr: $chrBanks0 $chrBanks1 prg: $prgBanks "
        "\n";
  }
}
