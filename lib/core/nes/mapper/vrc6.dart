import 'package:fnesemu/util/int.dart';
// Dart imports:
import 'dart:developer';
import 'dart:typed_data';

// Project imports:
import 'mapper.dart';
import 'mirror.dart';
import 'vrc6_apu.dart';

// https://www.nesdev.org/wiki/VRC6
class MapperVrc6 extends Mapper {
  final Vrc6Apu _apu = Vrc6Apu();

  // IRQ related counters, flags etc.
  int _irqLatch = 0;
  int _irqCounter = 0;
  bool _irqEnabled = false;
  bool _irqEnabledAfterAcknoledge = false;
  bool _irqModeCycle = false;

  // ram 8k 6000-7fff
  bool _ramEnabled = true;

  @override
  int get chrRomSizeK => 1;
  @override
  int get prgRomSizeK => 8;

  int _chrBankMask = 0;
  int _prgBankMask = 0;

  // ppu 8 x 1k banks, calculated from _ppuReg and the banking mode
  final List<int> _chrBank = [0, 0, 0, 0, 0, 0, 0, 0];

  final List<int> _ppuReg = [0, 0, 0, 0, 0, 0, 0, 0];

  // b003 bit0-1: ppu banking mode
  int _chrMode = 0;

  // b003 bit5: 2k banks take A10 from the ppu address
  bool _chrA10 = false;

  // cpu 16k + 8k + 8k banks (8000-bfff, c000-dfff, e000-ffff)
  // each item points one of _progBank0, _progBank2ndLast, _progBankA0
  final List<int> _prgBank = List.filled(4, 0);

  int _prgBank8000 = 0; // for 8000-bfff, 16k

  int mode = 0;

  @override
  void init() {
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
    if (addr == 0xb003) {
      _ramEnabled = data.bit7;

      _setMirror((data & 0x0f).shr2);

      _chrMode = data & 0x03;
      _chrA10 = data.bit5;
      _updateChrBank();

      return;
    }

    switch (addr & 0xf000) {
      case 0x6000:
      case 0x7000:
        if (_ramEnabled) {
          writeSram(addr & 0x1fff, data);
        }
        return;

      case 0x8000:
        _prgBank8000 = data & _prgBankMask.shr1;
        _prgBank[0] = _prgBank8000.shl1;
        _prgBank[1] = _prgBank8000.shl1 + 1;
        return;

      case 0xc000:
        _prgBank[2] = data & _prgBankMask;
        return;

      case 0x9000:
      case 0xa000:
      case 0xb000:
        _apu.write(addr & 0xf000 | addrToReg(addr), data);
        return;

      case 0xd000:
        _ppuReg[addrToReg(addr)] = data;
        _updateChrBank();
        return;

      case 0xe000:
        _ppuReg[0x04 | addrToReg(addr)] = data;
        _updateChrBank();
        return;

      case 0xf000:
        switch (addrToReg(addr)) {
          case 0:
            return _setIrqLatchLow(data);
          case 1:
            return _setIrqControl(data);
          case 2:
            return _setIrqAcknoledge();
        }
    }
  }

  // 1k bank for the half `lo` (0 or 1) of a 2k bank register
  int _chr2k(int reg, int lo) => _chrA10 ? (reg & 0xfe) | lo : reg;

  void _updateChrBank() {
    for (int i = 0; i < 8; i++) {
      final bank = switch (_chrMode) {
        0 => _ppuReg[i], // 1k x 8
        1 => _chr2k(_ppuReg[i.shr1], i & 1), // 2k x 4
        _ => i < 4 // 1k x 4 + 2k x 2
            ? _ppuReg[i]
            : _chr2k(_ppuReg[4 + (i - 4).shr1], i & 1),
      };
      _chrBank[i] = bank & _chrBankMask;
    }
  }

  // overriden in subclasses, which calls writeReg with mapped `reg`
  int addrToReg(int addr) {
    return addr & 0x03;
  }

  @override
  int read(int addr) {
    final bank = addr.shr13 & 0x03;
    final offset = addr & 0x1fff;

    if ((addr & 0xe000) == 0x6000) {
      return _ramEnabled ? readSram(offset) : 0xff;
    }
    if (addr & 0x8000 == 0x8000) {
      return prgRoms[_prgBank[bank]][offset];
    }
    return 0xff;
  }

  @override
  int readVram(int addr) {
    final bank = addr.shr10; // 1 1100 0000 0000
    final offset = addr & 0x03ff;

    return chrRoms[_chrBank[bank]][offset];
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
    _irqEnabledAfterAcknoledge = data.bit0;
    _irqEnabled = data.bit1;
    if (_irqEnabled) {
      _irqCounter = _irqLatch;
    }
    _prescaledClock = 0;
    _irqModeCycle = data.bit2;
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
  Float32List handleApu(int cycles) => _apu.exec(cycles);

  @override
  String dump() {
    final chrBanks =
        range(0, 8).map((i) => _chrBank[i].x2).toList().join(" ");
    final prgBanks =
        range(0, 4).map((i) => _prgBank[i].x2).toList().join(" ");
    final reg = _ppuReg.map((i) => i.x2).toList().join(" ");

    return "rom: irq:${_irqEnabled ? '*' : '-'}${_irqModeCycle ? 'c' : 's'} "
        "@${_irqCounter.d3z}"
        "/${_irqLatch.d3z} "
        "chr: $chrBanks prg: $prgBanks r:$reg "
        "ram:${_ramEnabled ? '*' : ' '}"
        "\n"
        "apu: ${_apu.dump()}"
        "\n";
  }
}

class MapperVrc6a extends MapperVrc6 {
  // VRC6a +0x00, +0x01, +0x02, +0x03
}

class MapperVrc6b extends MapperVrc6 {
  // VRC6b +0x00, +0x02, +0x01, +0x03
  @override
  int addrToReg(int addr) {
    return (addr & 1).shl1 | (addr & 2).shr1;
  }
}
