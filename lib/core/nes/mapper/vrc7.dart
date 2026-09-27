import 'package:fnesemu/util/int.dart';
// Dart imports:
import 'dart:developer';
import 'dart:typed_data';

// Project imports:
import 'mapper.dart';
import 'mirror.dart';
import 'vrc7_apu.dart';

// https://www.nesdev.org/wiki/VRC7
//
// iNES mapper 85. Both of VRC7a (A4: $x010) and VRC7b (A3: $x008) register
// layouts are accepted.
class MapperVrc7 extends Mapper {
  final Vrc7Apu _apu = Vrc7Apu();

  // IRQ related counters, flags etc.
  int _irqLatch = 0;
  int _irqCounter = 0;
  bool _irqEnabled = false;
  bool _irqEnabledAfterAcknoledge = false;
  bool _irqModeCycle = false;

  // ram 8k 6000-7fff
  bool _ramEnabled = false;
  bool _chrRam = false;

  @override
  int get chrRomSizeK => 1;
  @override
  int get prgRomSizeK => 8;

  int _chrBankMask = 0;
  int _prgBankMask = 0;

  // ppu 8 x 1k banks
  final List<int> _chrBank = [0, 1, 2, 3, 4, 5, 6, 7];

  // cpu 4 x 8k banks (8000-9fff, a000-bfff, c000-dfff, e000-ffff)
  final List<int> _prgBank = List.filled(4, 0);

  @override
  void init() {
    if (chrRoms.isEmpty) {
      // chr ram 1k x 8
      chrRoms.addAll(List.generate(8, (i) => Uint8List(1024)));
      _chrRam = true;
    }

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

    _prgBank[0] = 0;
    _prgBank[1] = 0;
    _prgBank[2] = 0;
    _prgBank[3] = prgRoms.length - 1;

    _apu.reset();
  }

  @override
  void write(int addr, int data) {
    if (addr & 0xe000 == 0x6000) {
      if (_ramEnabled) {
        writeSram(addr & 0x1fff, data);
      }
      return;
    }

    // audio registers: $9010 (address), $9030 (data)
    if (addr & 0xf030 == 0x9010) {
      return _apu.selectReg(data);
    }
    if (addr & 0xf030 == 0x9030) {
      return _apu.write(data);
    }

    // true if register is $x010 (VRC7a) or $x008 (VRC7b)
    final high = addr & 0x18 != 0;

    switch (addr & 0xf000) {
      case 0x8000:
        _prgBank[high ? 1 : 0] = data & 0x3f & _prgBankMask;
        return;

      case 0x9000:
        if (!high) {
          _prgBank[2] = data & 0x3f & _prgBankMask;
        }
        return;

      case 0xa000:
      case 0xb000:
      case 0xc000:
      case 0xd000:
        final bank = (addr.shr12 - 0x0a).shl1 + (high ? 1 : 0);
        _chrBank[bank] = data & _chrBankMask;
        return;

      case 0xe000:
        if (high) {
          _irqLatch = data;
        } else {
          _setControl(data);
        }
        return;

      case 0xf000:
        if (high) {
          _setIrqAcknoledge();
        } else {
          _setIrqControl(data);
        }
        return;
    }
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
    final bank = addr.shr10;
    final offset = addr & 0x03ff;

    return chrRoms[_chrBank[bank]][offset];
  }

  @override
  void writeVram(int addr, int data) {
    if (!_chrRam) {
      return;
    }

    final bank = addr.shr10;
    final offset = addr & 0x03ff;

    chrRoms[_chrBank[bank]][offset] = data;
  }

  static final _mirrors = [
    Mirror.vertical,
    Mirror.horizontal,
    Mirror.oneScreenLow,
    Mirror.oneScreenHigh,
  ];

  // $E000: RS.. ..MM (R: WRAM enable, S: silence audio, M: mirroring)
  void _setControl(int data) {
    _ramEnabled = data.bit7;
    _apu.mute = data.bit6;
    mirror(_mirrors[data & 0x03]);
  }

  void _setIrqControl(int data) {
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

  void _tickIrq() {
    _irqCounter += 1;

    if (_irqCounter == 0x100) {
      _irqCounter = _irqLatch;
      holdIrq(true);
    }
  }

  @override
  void handleClock(int cycles) {
    final elapsed = cycles - _prevCycle;
    _prevCycle = cycles;

    if (!_irqEnabled) {
      return;
    }

    if (_irqModeCycle) {
      for (int i = 0; i < elapsed; i++) {
        _tickIrq();
      }
      return;
    }

    _prescaledClock += elapsed * 3;

    while (_prescaledClock >= cyclesToTickIrq) {
      _prescaledClock -= cyclesToTickIrq;
      _tickIrq();
    }
  }

  @override
  Float32List handleApu(int cycles) => _apu.exec(cycles);

  @override
  String dump() {
    final chrBanks = range(0, 8).map((i) => _chrBank[i].x2).toList().join(" ");
    final prgBanks = range(0, 4).map((i) => _prgBank[i].x2).toList().join(" ");

    return "rom: irq:${_irqEnabled ? '*' : '-'}${_irqModeCycle ? 'c' : 's'} "
        "@${_irqCounter.d3z}"
        "/${_irqLatch.d3z} "
        "chr: $chrBanks prg: $prgBanks "
        "ram:${_ramEnabled ? '*' : ' '}"
        "\n"
        "apu: ${_apu.dump()}"
        "\n";
  }
}
