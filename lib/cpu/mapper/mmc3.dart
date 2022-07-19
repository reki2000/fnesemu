// Dart imports:
import 'dart:developer';
import 'dart:typed_data';

// Project imports:
import '../util.dart';
import 'mapper.dart';

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

  // ram
  final Uint8List _ram = Uint8List.fromList(List.filled(8 * 1024, 0));
  bool _ramEnabled = false;
  bool _ramWriteEnabled = false;

  // resized rom data, originally they are: chr:8k, prg:16k
  final List<Uint8List> _chrRom1k = [];
  final List<Uint8List> _prgRom8k = [];

  late final int _chrBankMask;
  late final int _prgBankMask;

  // ppu 2 x 4k banks (0000-0fff, 1000-1fff)
  //  each bank has 4 x 1k banks (000-3ff, 400-7ff, 800-bff, c00-fff)
  // each item points one of _chrBankR2_5 or _chrBankR0_1
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
  void init() {
    // resize chr roms from 8k to 1k
    for (final char8k in charRoms) {
      for (int i = 0; i < 8 * 1024; i += 1024) {
        _chrRom1k.add(char8k.sublist(i, i + 1024));
      }
    }
    _chrBank[0] = _chrBankR2_5;
    _chrBank[1] = _chrBankR0_1;
    _chrBankMask = _chrRom1k.length - 1;
    if (_chrRom1k.length & _chrBankMask != 0) {
      log("invalid chr rom size: ${_chrBank.length}k");
      return;
    }

    // resize prg roms from 16k to 8k
    for (final prog16k in programRoms) {
      for (int i = 0; i < 16 * 1024; i += 8 * 1024) {
        _prgRom8k.add(prog16k.sublist(i, i + 8 * 1024));
      }
    }
    _prgBankMask = _prgRom8k.length - 1;
    if (_prgBankMask & _prgRom8k.length != 0) {
      log("invalid prg rom size: ${_prgRom8k.length}k");
      return;
    }

    _prgBank2ndLast[0] = _prgRom8k.length - 2;
    _prgBank[0] = _prgBank0; // 0x8000-0x9fff
    _prgBank[1] = _prgBankA000; // 0xa000-0xbfff
    _prgBank[2] = _prgBank2ndLast; // 0xc000-0xdfff
    _prgBank[3] = [_prgRom8k.length - 1]; // 0xe000-0xffff
  }

  @override
  void write(int addr, int data) {
    final reg = addr & 0xe000;
    final isOdd = bit0(addr);

    switch (reg) {
      case 0x6000:
        if (_ramEnabled && _ramWriteEnabled) {
          _ram[addr & 0x1fff] = data;
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
          mirrorVertical(!bit0(data));
        }
        break;

      case 0xc000:
        if (isOdd) {
          _irqReload = true;
          _irqCounter = 0;
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
      return _ramEnabled ? _ram[offset] : 0xff;
    }

    return _prgRom8k[_prgBank[bank][0]][offset];
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

    return _chrRom1k[_chrBank[bank >> 2][bank & 0x03]][offset];
  }

  void _tickIrq() {
    if (_irqCounter == 0 && _irqEnabled) {
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
