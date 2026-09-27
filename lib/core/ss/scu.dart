import 'package:fnesemu/util/int.dart';

import 'bus.dart';
import 'scu_dsp.dart';

/// System Control Unit: interrupt controller, DMA, timers and DSP
class Scu {
  final Bus bus;
  late final ScuDsp dsp;

  Scu(this.bus) {
    dsp = ScuDsp(this);
  }

  // interrupt sources (bit numbers of IST / IMS)
  static const intVBlankIn = 0;
  static const intVBlankOut = 1;
  static const intHBlankIn = 2;
  static const intTimer0 = 3;
  static const intTimer1 = 4;
  static const intDspEnd = 5;
  static const intSoundRequest = 6;
  static const intSystemManager = 7;
  static const intPad = 8;
  static const intDma2End = 9;
  static const intDma1End = 10;
  static const intDma0End = 11;
  static const intDmaIllegal = 12;
  static const intSpriteDrawEnd = 13;
  static const intExternal0 = 16; // CD block

  static const _levels = [
    0xf, 0xe, 0xd, 0xc, 0xb, 0xa, 0x9, 0x8, //
    0x8, 0x6, 0x6, 0x5, 0x3, 0x2, 0x0, 0x0, //
    0x7, 0x7, 0x7, 0x7, 0x4, 0x4, 0x4, 0x4, //
    0x1, 0x1, 0x1, 0x1, 0x1, 0x1, 0x1, 0x1, //
  ];

  // callbacks to set IRL of the SH-2s
  void Function(int level) onMasterIrl = (_) {};
  void Function(int level) onSlaveIrl = (_) {};

  int ist = 0;
  int ims = 0xbfff;

  // slave SH-2 interrupts: hblank-in (level 2) and vblank-in (level 6)
  bool _slaveVBlank = false;
  bool _slaveHBlank = false;

  // DMA start factors (DnMD bits 2-0)
  static const factorVBlankIn = 0;
  static const factorVBlankOut = 1;
  static const factorHBlankIn = 2;
  static const factorTimer0 = 3;
  static const factorTimer1 = 4;
  static const factorSoundRequest = 5;
  static const factorSpriteDrawEnd = 6;
  static const factorManual = 7;

  final dma = List.generate(3, (i) => ScuDma(i));

  // timers
  int t0c = 0;
  int t1s = 0;
  int t1md = 0;
  int _timer0Counter = 0;

  int asr0 = 0, asr1 = 0, aref = 0, rsel = 0;

  void reset() {
    ist = 0;
    ims = 0xbfff;
    _slaveVBlank = false;
    _slaveHBlank = false;
    for (final d in dma) {
      d.reset();
    }
    t0c = 0;
    t1s = 0;
    t1md = 0;
    _timer0Counter = 0;
    dsp.reset();
    _updateIrl();
  }

  // interrupt handling

  void raise(int source) {
    ist |= 1 << source;
    _updateIrl();
  }

  // internal interrupts are masked per bit, A-bus interrupts by IMS bit 15
  int _pendingMask() =>
      ist & ~ims & 0x3fff | ist & (ims.bit15 ? 0 : 0xffff0000);

  int _highestSource() {
    final pending = _pendingMask();
    if (pending == 0) {
      return -1;
    }

    int best = -1;
    int bestLevel = 0;
    for (int i = 0; i < 32; i++) {
      if (pending & (1 << i) != 0 && _levels[i] > bestLevel) {
        best = i;
        bestLevel = _levels[i];
      }
    }
    return best;
  }

  void _updateIrl() {
    final src = _highestSource();
    onMasterIrl(src < 0 ? 0 : _levels[src]);
  }

  /// called by the master SH-2 on interrupt acceptance, returns vector number
  int acknowledgeMaster() {
    final src = _highestSource();
    if (src < 0) {
      return 0x40; // spurious
    }
    ist &= ~(1 << src);
    _updateIrl();
    return src < 16 ? 0x40 + src : 0x50 + (src - 16);
  }

  void _updateSlaveIrl() =>
      onSlaveIrl(_slaveVBlank ? 6 : (_slaveHBlank ? 2 : 0));

  int acknowledgeSlave() {
    if (_slaveVBlank) {
      _slaveVBlank = false;
      _updateSlaveIrl();
      return 0x43;
    }
    if (_slaveHBlank) {
      _slaveHBlank = false;
      _updateSlaveIrl();
      return 0x41;
    }
    return 0x40;
  }

  // timing events from VDP2

  void onVBlankIn() {
    raise(intVBlankIn);
    _slaveVBlank = true;
    _updateSlaveIrl();
    _startDmaByFactor(factorVBlankIn);
  }

  void onVBlankOut() {
    _timer0Counter = 0;
    raise(intVBlankOut);
    _startDmaByFactor(factorVBlankOut);
  }

  void onHBlankIn() {
    raise(intHBlankIn);
    _slaveHBlank = true;
    _updateSlaveIrl();
    _startDmaByFactor(factorHBlankIn);

    // timer 0 counts h-blanks, timer 1 fires once per line
    if (t1md.bit0) {
      final t0match = _timer0Counter == t0c;
      if (t0match) {
        raise(intTimer0);
        _startDmaByFactor(factorTimer0);
      }
      if (!t1md.bit8 || t0match) {
        raise(intTimer1);
        _startDmaByFactor(factorTimer1);
      }
    }
    _timer0Counter = (_timer0Counter + 1) & 0x3ff;
  }

  void onSoundRequest() {
    raise(intSoundRequest);
    _startDmaByFactor(factorSoundRequest);
  }

  void onSpriteDrawEnd() {
    raise(intSpriteDrawEnd);
    _startDmaByFactor(factorSpriteDrawEnd);
  }

  void onSystemManager() => raise(intSystemManager);

  void onDspEnd() => raise(intDspEnd);

  void setExternal(int no) => raise(intExternal0 + no);

  // registers

  int read32(int addr) {
    if (addr < 0x60) {
      return dma[addr ~/ 0x20].read(addr & 0x1f);
    }

    return switch (addr) {
      0x7c => 0, // DSTA: DMA status, never busy
      0x80 => dsp.readControl(),
      0x8c => dsp.readData(),
      0xa0 => ims,
      0xa4 => ist,
      0xa8 => 0, // AIACK
      0xb0 => asr0,
      0xb4 => asr1,
      0xb8 => aref,
      0xc4 => rsel,
      0xc8 => 0x04, // version
      _ => 0,
    };
  }

  void write32(int addr, int data, int mask) {
    if (addr < 0x60) {
      final ch = dma[addr ~/ 0x20];
      final reg = addr & 0x1f;
      ch.write(reg, ch.read(reg) & ~mask | data & mask);
      if (reg == 0x10 && ch.enabled && ch.factor == factorManual && data.bit0) {
        _execDma(ch);
      }
      return;
    }

    switch (addr) {
      case 0x60: // DSTP
        break;
      case 0x80:
        dsp.writeControl(data & mask);
        break;
      case 0x84:
        dsp.writeProgram(data);
        break;
      case 0x88:
        dsp.writeDataAddr(data);
        break;
      case 0x8c:
        dsp.writeData(data);
        break;
      case 0x90:
        t0c = (t0c & ~mask | data & mask) & 0x3ff;
        break;
      case 0x94:
        t1s = (t1s & ~mask | data & mask) & 0x1ff;
        break;
      case 0x98:
        t1md = (t1md & ~mask | data & mask) & 0x101;
        break;
      case 0xa0:
        ims = (ims & ~mask | data & mask) & 0xbfff;
        _updateIrl();
        break;
      case 0xa4:
        // writing 0 clears the status bits
        ist &= data | ~mask;
        _updateIrl();
        break;
      case 0xa8:
        break;
      case 0xb0:
        asr0 = asr0 & ~mask | data & mask;
        break;
      case 0xb4:
        asr1 = asr1 & ~mask | data & mask;
        break;
      case 0xb8:
        aref = aref & ~mask | data & mask;
        break;
      case 0xc4:
        rsel = rsel & ~mask | data & mask;
        break;
    }
  }

  // DMA

  void _startDmaByFactor(int factor) {
    for (final ch in dma) {
      if (ch.enabled && ch.factor == factor) {
        _execDma(ch);
      }
    }
  }

  static const _writeAddTable = [0, 2, 4, 8, 16, 32, 64, 128];

  void _execDma(ScuDma ch) {
    final readAdd = ch.add.bit8 ? 4 : 0;
    final writeAdd = _writeAddTable[ch.add & 7];

    if (ch.indirect) {
      int table = ch.writeAddr & 0x7fffffc;
      for (int i = 0; i < 0x1000; i++) {
        final count = bus.read32(table);
        final dst = bus.read32(table + 4);
        final srcAndEnd = bus.read32(table + 8);
        table += 12;

        final countMasked =
            ch.level == 0 ? count.maskZeroMax(0xfffff) : count.maskZeroMax(0xfff);
        transfer(srcAndEnd & 0x7ffffff, dst & 0x7ffffff, countMasked, readAdd,
            writeAdd);

        if (srcAndEnd.bit31) {
          break;
        }
      }

      if (ch.writeUpdate) {
        ch.writeAddr = table;
      }
    } else {
      final count = ch.level == 0
          ? ch.count.maskZeroMax(0xfffff)
          : ch.count.maskZeroMax(0xfff);
      final (src, dst) = transfer(
          ch.readAddr & 0x7ffffff, ch.writeAddr & 0x7ffffff, count, readAdd, writeAdd);
      if (ch.readUpdate) {
        ch.readAddr = src;
      }
      if (ch.writeUpdate) {
        ch.writeAddr = dst;
      }
    }

    raise(switch (ch.level) {
      0 => intDma0End,
      1 => intDma1End,
      _ => intDma2End,
    });
  }

  static bool _isBBus(int addr) => addr >= 0x5a00000 && addr < 0x5ff0000;

  /// transfers `count` bytes, returns updated (src, dst)
  (int, int) transfer(int src, int dst, int count, int readAdd, int writeAdd) {
    final bBus = _isBBus(dst);

    if (bBus) {
      // B-bus is 16-bit wide: the source is read in 16-bit units
      for (int i = 0; i < count; i += 2) {
        final d = src.bit0
            ? bus.read8(src) << 8 | bus.read8(src + 1)
            : bus.read16(src);
        bus.write16(dst, d);
        dst += writeAdd;
        if (readAdd != 0) {
          src += 2;
        }
      }
      return (src, dst);
    }

    final dstAdd = writeAdd == 0 ? 0 : (writeAdd < 4 ? 4 : writeAdd);
    int i = 0;
    for (; i + 4 <= count; i += 4) {
      final d = src & 3 != 0
          ? bus.read8(src) << 24 |
              bus.read8(src + 1) << 16 |
              bus.read8(src + 2) << 8 |
              bus.read8(src + 3)
          : bus.read32(src);
      bus.write32(dst, d);
      src += readAdd;
      dst += dstAdd;
    }
    for (; i < count; i++) {
      bus.write8(dst, bus.read8(src));
      if (readAdd != 0) src++;
      if (dstAdd != 0) dst++;
    }
    return (src, dst);
  }

  String dump() =>
      "scu: ist:${ist.x8} ims:${ims.x8} t0c:${t0c.x4} t1s:${t1s.x4} t1md:${t1md.x4} ${dsp.dump()}";
}

class ScuDma {
  final int level;
  ScuDma(this.level);

  int readAddr = 0;
  int writeAddr = 0;
  int count = 0;
  int add = 0x101;
  int en = 0;
  int md = 0x7;

  bool get enabled => en.bit8;
  int get factor => md & 7;
  bool get indirect => md.bit24;
  bool get readUpdate => md.bit16;
  bool get writeUpdate => md.bit8;

  void reset() {
    readAddr = 0;
    writeAddr = 0;
    count = 0;
    add = 0x101;
    en = 0;
    md = 7;
  }

  int read(int reg) => switch (reg) {
        0x00 => readAddr,
        0x04 => writeAddr,
        0x08 => count,
        0x0c => add,
        0x10 => en,
        0x14 => md,
        _ => 0,
      };

  void write(int reg, int data) {
    switch (reg) {
      case 0x00:
        readAddr = data & 0x7ffffff;
        break;
      case 0x04:
        writeAddr = data & 0x7ffffff;
        break;
      case 0x08:
        count = data & (level == 0 ? 0xfffff : 0xfff);
        break;
      case 0x0c:
        add = data & 0x107;
        break;
      case 0x10:
        en = data & 0x101;
        break;
      case 0x14:
        md = data & 0x1010107;
        break;
    }
  }
}
