// Dart imports:
import 'dart:developer';
import 'dart:typed_data';

// Project imports:
import '../../util.dart';
import 'mapper.dart';
import 'mirror.dart';

// https://www.nesdev.org/wiki/VRC6
class MapperVrc6 extends Mapper {
  // IRQ related counters, flags etc.
  int _irqLatch = 0;
  int _irqCounter = 0;
  bool _irqEnabled = false;
  bool _irqEnabledAfterAcknoledge = false;
  bool _irqModeCycle = false;

  // ram 8k 6000-7fff
  final Uint8List _ram = Uint8List(8 * 1024);
  bool _ramEnabled = true;

  int _chrBankMask = 0;
  int _prgBankMask = 0;

  // ppu 8 x 1k banks
  final List<int> _chrBank = [0, 1, 2, 3, 4, 5, 6, 7];
  final List<int> _namBank = [0, 1, 2, 3];

  final List<int> _ppuReg = [0, 0, 0, 0, 0, 0, 0, 0];

  // cpu 16k + 8k + 8k banks (8000-bfff, c000-dfff, e000-ffff)
  // each item points one of _progBank0, _progBank2ndLast, _progBankA0
  final List<int> _prgBank = List.filled(4, 0);

  int _prgBank8000 = 0; // for 8000-bfff, 16k

  int mode = 0;

  @override
  void init() {
    loadRom(chrBankSizeK: 1, prgBankSizeK: 8);

    _chrBankMask = chrRoms.length - 1;
    if (chrRoms.length & _chrBankMask != 0) {
      log("invalid chr rom size: ${chrRoms.length}k");
      return;
    }

    _prgBankMask = prgRoms.length - 1;
    if (_prgBankMask & prgRoms.length != 0) {
      log("invalid prg rom size: ${prgRoms.length}k");
      return;
    }

    _prgBank[0] = 0; // 0x8000-0x9fff
    _prgBank[1] = 0; // 0xa000-0xbfff
    _prgBank[2] = 0; // 0xc000-0xdfff
    _prgBank[3] = prgRoms.length - 1; // 0xe000-0xffff
  }

  @override
  void write(addr, data) {
    switch (addr & 0xf000) {
      case 0x6000:
      case 0x7000:
        if (_ramEnabled) {
          _ram[addr & 0x1fff] = data;
        }
        break;

      case 0x8000:
        _prgBank8000 = data & _prgBankMask;
        _prgBank[0] = _prgBank8000 << 1;
        _prgBank[1] = (_prgBank8000 << 1) + 1;
        break;
      case 0xc000:
        _prgBank[2] = data & _prgBankMask;
        break;

      case 0xb000:
        if (addr == 0xb003) {
          _ramEnabled = bit7(data);

          _setMirror(data >> 4);

          switch (data & 0x03) {
            case 0:
              for (int i = 0; i < 8; i++) {
                _chrBank[i] = i;
              }
              break;
            case 1:
              for (var i = 0; i < 8; i++) {
                _chrBank[i] = i >> 1;
              }
              break;

            case 2:
            case 3:
              for (var i = 0; i < 4; i++) {
                _chrBank[i] = i;
              }
              for (var i = 4; i < 8; i++) {
                _chrBank[i] = i >> 1;
              }
              break;
          }
        }
        break;

      case 0xd000:
      case 0xe000:
        writeExt(addr, data);
        break;

      case 0xf000:
        final reg = addr & 0x03;
        switch (reg) {
          case 0:
            return _setIrqLatchLow(data);
          case 1:
            return _setIrqControl(data);
          case 2:
            return _setIrqAcknoledge();
        }
        break;
    }
  }

  // overriden in subclasses, which calls writeReg with mapped `reg`
  void writeExt(addr, data) {}

  void writeReg(int reg, int data) {
    _ppuReg[reg] = data;
  }

  @override
  int read(int addr) {
    final bank = (addr >> 13) & 0x03;
    final offset = addr & 0x1fff;

    if ((addr & 0xe000) == 0x6000) {
      return _ramEnabled ? _ram[offset] : 0xff;
    }
    if (addr & 0x8000 == 0x8000) {
      return prgRoms[_prgBank[bank]][offset];
    }
    return 0xff;
  }

  @override
  int readVram(int addr) {
    final bank = addr >> 10; // 1 1100 0000 0000
    final offset = addr & 0x03ff;

    return chrRoms[_ppuReg[_chrBank[bank]]][offset];
  }

  static final _mirrors = [
    Mirror.vertical,
    Mirror.horizontal,
    Mirror.oneScreenLow,
    Mirror.oneScreenHigh
  ];

  void _setMirror(int data) {
    mirror(_mirrors[data & 0x03]);
  }

  void _setIrqLatchLow(data) {
    _irqLatch = data;
    holdIrq(false);
  }

  void _setIrqControl(data) {
    _irqEnabledAfterAcknoledge = bit0(data);
    _irqEnabled = bit1(data);
    if (_irqEnabled) {
      _irqCounter = _irqLatch;
    }
    _prescaledClock = 0;
    _irqModeCycle = bit2(data);
    holdIrq(false);
  }

  void _setIrqAcknoledge() {
    _irqEnabled = _irqEnabledAfterAcknoledge;
    holdIrq(false);
  }

  static const cyclesToTickIrq = 341;
  int _prescaledClock = 0;
  int _prevCycle = 0;

  @override
  void handleClock(int cycles) {
    if (_irqEnabled && !_irqModeCycle) {
      _prescaledClock += (cycles - _prevCycle) * 3;

      while (_prescaledClock >= cyclesToTickIrq) {
        _prescaledClock -= cyclesToTickIrq;
        _irqCounter += 1;

        if (_irqCounter == 0x100) {
          _irqCounter = _irqLatch;
          holdIrq(true);
        }
      }
    }
    _prevCycle = cycles;
  }

  @override
  String dump() {
    final chrBanks =
        range(0, 8).map((i) => hex8(_chrBank[i])).toList().join(" ");
    final prgBanks =
        range(0, 4).map((i) => hex8(_prgBank[i])).toList().join(" ");
    final reg = _ppuReg.map((i) => hex8(i)).toList().join(" ");

    return "rom: irq:${_irqEnabled ? '*' : '-'}${_irqModeCycle ? 'c' : 's'} "
        "@${_irqCounter.toRadixString(10).padLeft(3, "0")}"
        "/${_irqLatch.toRadixString(10).padLeft(3, "0")} "
        "chr: $chrBanks prg: $prgBanks r:$reg "
        "ram:${_ramEnabled ? '*' : ' '}"
        "\n";
  }
}

class MapperVrc6a extends MapperVrc6 {
  // VRC6a +0x00, +0x01, +0x02, +0x03
  @override
  void writeExt(addr, data) {
    return writeReg((((addr - 0xd000) & 0xf000) >> 10) | addr & 0x03, data);
  }
}

class MapperVrc6b extends MapperVrc6 {
  // VRC6b +0x00, +0x02, +0x01, +0x03
  @override
  void writeExt(addr, data) {
    return writeReg(
        (((addr - 0xd000) & 0xf000) >> 10) | (addr & 1) << 1 | (addr & 2) >> 1,
        data);
  }
}
