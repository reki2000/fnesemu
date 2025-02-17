// Dart imports:
import 'dart:developer';

// Project imports:
import '../../../util/util.dart';
import 'mapper.dart';
import 'mirror.dart';
import 'sram.dart';

// https://www.nesdev.org/wiki/VRC2_and_VRC4
class MapperVrc4 extends Mapper with Sram {
  // IRQ related counters, flags etc.
  int _irqLatch = 0;
  int _irqCounter = 0;
  bool _irqEnabled = false;
  bool _irqEnabledAfterAcknoledge = false;
  bool _irqModeCycle = false;

  // ram 8k
  bool _ramEnabled = true;

  @override
  int get chrRomSizeK => 1;
  @override
  int get prgRomSizeK => 8;

  int _chrBankMask = 0;
  int _prgBankMask = 0;

  // ppu 8 x 1k banks
  final List<int> _chrBank = [0, 1, 2, 3, 4, 5, 6, 7];

  // cpu 4 x 8k banks (8000-9fff, a000-bfff, c000-dfff, e000-ffff)
  // each item points one of _progBank0, _progBank2ndLast, _progBankA0
  final List<List<int>> _prgBank = List.filled(4, []);

  final _prgBank0 = [0]; // for 8000-9fff or c000-dfff
  final _prgBank2ndLast = [0]; // for 8000-9fff or c000-dfff
  final _prgBankA000 = [0]; // for a000-bfff

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

    _prgBank2ndLast[0] = prgRoms.length - 2;
    _prgBank[0] = _prgBank0; // 0x8000-0x9fff
    _prgBank[1] = _prgBankA000; // 0xa000-0xbfff
    _prgBank[2] = _prgBank2ndLast; // 0xc000-0xdfff
    _prgBank[3] = [prgRoms.length - 1]; // 0xe000-0xffff
  }

  @override
  void write(addr, data) {
    if ((addr & 0xe000 == 0x6000) && _ramEnabled) {
      ram[addr & 0x1fff] = data;
      return;
    }

    writeExt(addr, data);
  }

  // overriden in subclasses, which calls writeReg with mapped `reg`
  void writeExt(addr, data) {}

  void writeReg(int addr, int reg, int data) {
    switch (addr & 0xf000) {
      case 0x9000:
        switch (reg) {
          case 2:
            return _setControl(data);
          default:
            return _setMirror(data);
        }

      case 0x8000:
        _prgBank0[0] = data & _prgBankMask;
        break;
      case 0xa000:
        _prgBankA000[0] = data & _prgBankMask;
        break;

      case 0xb000:
      case 0xc000:
      case 0xd000:
      case 0xe000:
        final bank = (((addr >> 12) - 0x0b) << 1);
        switch (reg) {
          case 0:
            return _setChrLow(bank, data);
          case 1:
            return _setChrHigh(bank, data);
          case 2:
            return _setChrLow(bank + 1, data);
          case 3:
            return _setChrHigh(bank + 1, data);
        }
        break;

      case 0xf000:
        switch (reg) {
          case 0:
            return _setIrqLatchLow(data);
          case 1:
            return _setIrqLatchHigh(data);
          case 2:
            return _setIrqControl(data);
          case 3:
            return _setIrqAcknoledge();
        }
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
    if (addr & 0x8000 == 0x8000) {
      return prgRoms[_prgBank[bank][0]][offset];
    }
    return 0xff;
  }

  @override
  int readVram(int addr) {
    final bank = addr >> 10; // 1 1100 0000 0000
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

  void _setControl(int data) {
    _ramEnabled = bit0(data);

    if (bit1(data)) {
      _prgBank[0] = _prgBank2ndLast;
      _prgBank[2] = _prgBank0;
    } else {
      _prgBank[0] = _prgBank0;
      _prgBank[2] = _prgBank2ndLast;
    }
  }

  void _setChrLow(int bank, int data) {
    _chrBank[bank] = (_chrBank[bank] & 0x1f0) | (data & 0x0f);
  }

  void _setChrHigh(int bank, int data) {
    _chrBank[bank] = (_chrBank[bank] & 0x0f) | ((data & 0x1f) << 4);
  }

  void _setIrqLatchLow(data) {
    _irqLatch = _irqLatch.with4Bit(data);
    holdIrq(false);
  }

  void _setIrqLatchHigh(data) {
    _irqLatch = _irqLatch.with4Bit(data, lsbPosition: 4);
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
        range(0, 4).map((i) => hex8(_prgBank[i][0])).toList().join(" ");

    return "rom: irq:${_irqEnabled ? '*' : '-'}${_irqModeCycle ? 'c' : 's'} "
        "@${_irqCounter.toRadixString(10).padLeft(3, "0")}"
        "/${_irqLatch.toRadixString(10).padLeft(3, "0")} "
        "chr: $chrBanks prg: $prgBanks "
        "ram:${_ramEnabled ? '*' : ' '}"
        "\n";
  }
}

class MapperVrc4a4c extends MapperVrc4 {
  // VRC4a +0x00, +0x02, +0x04, +0x06
  // VRC4c +0x00, +0x40, +0x80, +0xc0
  @override
  void writeExt(addr, data) {
    switch (addr & 0x0fff) {
      case 0x00:
        return writeReg(addr, 0, data);
      case 0x02:
      case 0x40:
        return writeReg(addr, 1, data);
      case 0x04:
      case 0x80:
        return writeReg(addr, 2, data);
      case 0x06:
      case 0xc0:
        return writeReg(addr, 3, data);
    }
  }
}

class MapperVrc4f4e extends MapperVrc4 {
  // VRC4f +0x00, +0x01, +0x02, +0x03
  // VRC4e +0x00, +0x04, +0x08, +0x0c
  @override
  void writeExt(addr, data) {
    switch (addr & 0x0fff) {
      case 0x00:
        return writeReg(addr, 0, data);
      case 0x01:
      case 0x04:
        return writeReg(addr, 1, data);
      case 0x02:
      case 0x08:
        return writeReg(addr, 2, data);
      case 0x03:
      case 0x0c:
        return writeReg(addr, 3, data);
    }
  }
}

class MapperVrc4b4d extends MapperVrc4 {
  // VRC4b +0x00, +0x02, +0x01, +0x03
  // VRC4d +0x00, +0x08, +0x04, +0x0c
  @override
  void writeExt(addr, data) {
    switch (addr & 0x0fff) {
      case 0x00:
        return writeReg(addr, 0, data);
      case 0x02:
      case 0x08:
        return writeReg(addr, 1, data);
      case 0x01:
      case 0x04:
        return writeReg(addr, 2, data);
      case 0x03:
      case 0x0c:
        return writeReg(addr, 3, data);
    }
  }
}
