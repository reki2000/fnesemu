import '../sif.dart';
import 'cdvd.dart';
import 'iop_memory.dart';
import 'sio2.dart';

/// IOP interrupt numbers
class IopIrq {
  static const vblankStart = 0, cdvd = 2, dma = 3, timer0 = 4, timer1 = 5;
  static const timer2 = 6, sio0 = 7, sio1 = 8, spu2 = 9, vblankEnd = 11;
  static const timer3 = 14, timer4 = 15, timer5 = 16, sio2 = 17;
}

/// A DMA channel of the IOP.
class IopDmaChannel {
  int madr = 0, bcr = 0, chcr = 0, tadr = 0;
}

/// The IOP internal registers: interrupt controller, DMA controller, timers
/// and the SIF mailbox. Other addresses read back what was written.
///
/// Uncertain details (to be checked against hardware tests): the DICR2 bit
/// layout, which timer clock sources exist, and the SIF packet tags.
class IopIo implements IopPort {
  static const _channelCount = 14;
  static const _start = 1 << 24;
  static const _chain = 1 << 10;

  /// CHCR bit 30 on the SIF channels: the data starts with a tag (observed
  /// from BIOS use; unverified)
  static const _tagMode = 1 << 30;

  final IopMemory memory;
  final Sif sif;
  final cdvd = Cdvd();
  final sio2 = Sio2();

  int stat = 0, mask = 0, ctrl = 0;
  final channels = List.generate(_channelCount, (_) => IopDmaChannel());
  int dpcr = 0, dicr = 0, dpcr2 = 0, dicr2 = 0;

  /// Device hooks per DMA channel. A handler transfers the channel and returns
  /// true when done, or false to be retried later. Without a handler a channel
  /// completes immediately.
  final dmaHandlers =
      List<bool Function(IopDmaChannel)?>.filled(_channelCount, null);

  final _timerCount = List<int>.filled(6, 0);
  final _timerMode = List<int>.filled(6, 0);
  final _timerTarget = List<int>.filled(6, 0);
  final _timerFraction = List<int>.filled(6, 0);

  final _backing = <int, int>{};

  /// true when the interrupt output may have changed
  bool dirty = false;

  IopIo(this.memory, this.sif) {
    memory.port = this;
    sio2.onInterrupt = () => raise(IopIrq.sio2);
    cdvd.onInterrupt = () => raise(IopIrq.cdvd);
    dmaHandlers[3] = _cdvdIn;
    dmaHandlers[11] = _sio2In;
    dmaHandlers[12] = _sio2Out;
    dmaHandlers[9] = _sif0;
    dmaHandlers[10] = _sif1;
  }

  bool get asserted => ctrl != 0 && (stat & mask) != 0;

  void raise(int irq) {
    stat |= 1 << irq;
    dirty = true;
  }

  // ---- registers ----

  @override
  int read(int address, int size) {
    if (address >= 0x1d000000 && address < 0x1d000100) {
      return sif.iopRead(address & 0xff);
    }
    if (Cdvd.handles(address)) return cdvd.read(address);
    if (Sio2.handles(address)) return sio2.read(address, size);
    switch (address) {
      case 0x1f801070:
        return stat;
      case 0x1f801074:
        return mask;
      case 0x1f801078:
        final v = ctrl;
        ctrl = 0; // reading acknowledges the global enable
        dirty = true;
        return v;
      case 0x1f8010f0:
        return dpcr;
      case 0x1f8010f4:
        return _dicrValue(dicr);
      case 0x1f801570:
        return dpcr2;
      case 0x1f801574:
        return _dicrValue(dicr2, second: true);
    }
    final ch = _channelOf(address);
    if (ch >= 0) {
      final c = channels[ch];
      return switch (address & 0xf) {
        0x0 => c.madr,
        0x4 => c.bcr,
        0x8 => c.chcr,
        0xc => c.tadr,
        _ => 0,
      };
    }
    final t = _timerOf(address);
    if (t >= 0) return _timerRead(t, address & 0xf);
    // SPU2: STATX of both cores reports ready (bit 7); other registers read
    // back as written
    if (address == 0x1f900344 || address == 0x1f900744) return 0x80;
    var v = 0;
    for (var i = size - 1; i >= 0; i--) {
      v = (v << 8) | (_backing[address + i] ?? 0);
    }
    return v;
  }

  @override
  void write(int address, int size, int value) {
    if (address >= 0x1d000000 && address < 0x1d000100) {
      sif.iopWrite(address & 0xff, value);
      return;
    }
    if (Cdvd.handles(address)) {
      cdvd.write(address, value);
      return;
    }
    if (Sio2.handles(address)) {
      sio2.write(address, size, value);
      return;
    }
    switch (address) {
      case 0x1f801070:
        stat &= value; // writing 0 acknowledges
        dirty = true;
        return;
      case 0x1f801074:
        mask = value;
        dirty = true;
        return;
      case 0x1f801078:
        ctrl = value & 1;
        dirty = true;
        return;
      case 0x1f8010f0:
        dpcr = value;
        service();
        return;
      case 0x1f8010f4:
        dicr = _dicrWrite(dicr, value);
        dirty = true;
        return;
      case 0x1f801570:
        dpcr2 = value;
        service();
        return;
      case 0x1f801574:
        dicr2 = _dicrWrite(dicr2, value);
        dirty = true;
        return;
    }
    final ch = _channelOf(address);
    if (ch >= 0) {
      final c = channels[ch];
      switch (address & 0xf) {
        case 0x0:
          c.madr = value & 0xffffff;
        case 0x4:
          c.bcr = value;
        case 0x8:
          c.chcr = value;
          if (value & _start != 0) _runChannel(ch);
        case 0xc:
          c.tadr = value & 0xffffff;
      }
      return;
    }
    final t = _timerOf(address);
    if (t >= 0) {
      _timerWrite(t, address & 0xf, value);
      return;
    }
    for (var i = 0; i < size; i++) {
      _backing[address + i] = (value >> (8 * i)) & 0xff;
    }
  }

  // ---- DMA ----

  static int _channelOf(int address) {
    if (address >= 0x1f801080 && address < 0x1f8010f0) {
      return (address - 0x1f801080) >> 4;
    }
    if (address >= 0x1f801500 && address < 0x1f801560) {
      return 7 + ((address - 0x1f801500) >> 4);
    }
    return -1;
  }

  bool _enabled(int ch) => ch < 7
      ? (dpcr >> (ch * 4 + 3)) & 1 != 0
      : (dpcr2 >> ((ch - 7) * 4 + 3)) & 1 != 0;

  /// DICR: bit 15 forces the flag, 16.. are enables, 23 master enable,
  /// 24.. are the flags (write 1 to clear), bit 31 the master flag
  int _dicrValue(int v, {bool second = false}) {
    final flags = (v >> 24) & 0x7f, enables = (v >> 16) & 0x7f;
    // the master enable of DICR2 is bit 10 (observed from BIOS writes;
    // unverified)
    final masterEnable = second ? (v >> 10) & 1 != 0 : (v >> 23) & 1 != 0;
    final master =
        (v >> 15) & 1 != 0 || (masterEnable && (flags & enables) != 0);
    return (v & 0x7fffffff) | (master ? 0x80000000 : 0);
  }

  int _dicrWrite(int old, int v) {
    final flags = (old >> 24) & 0x7f & ~((v >> 24) & 0x7f);
    return (v & 0x00ffffff) | (flags << 24);
  }

  void _complete(int ch) {
    final c = channels[ch];
    c.chcr &= ~_start;
    final index = ch < 7 ? ch : ch - 7;
    final reg = ch < 7 ? dicr : dicr2;
    var next = reg;
    if ((reg >> (16 + index)) & 1 != 0) next |= 1 << (24 + index);
    if (ch < 7) {
      dicr = next;
    } else {
      dicr2 = next;
    }
    if (_dicrValue(next, second: ch >= 7) & 0x80000000 != 0) raise(IopIrq.dma);
  }

  void _runChannel(int ch) {
    if (!_enabled(ch)) return;
    final handler = dmaHandlers[ch];
    if (handler == null || handler(channels[ch])) _complete(ch);
  }

  /// retries the channels that are waiting
  void service() {
    for (var ch = 0; ch < _channelCount; ch++) {
      if (channels[ch].chcr & _start != 0) _runChannel(ch);
    }
  }

  /// words of a non-chain transfer
  static int _words(IopDmaChannel c) {
    final size = c.bcr & 0xffff, count = (c.bcr >>> 16) & 0xffff;
    return c.chcr & 0x600 == 0x200 ? size * (count == 0 ? 1 : count) : size;
  }

  // SIF packets start with a quadword whose first two words are the IOP
  // tag: address | flags (bit 31 end, bit 30 interrupt) and a word count.
  // The data follows, padded to quadwords. Unverified.
  int _sif1Left = 0, _sif1Address = 0, _sif1Pad = 0;
  bool _sif1End = false;

  /// SIF1: EE to IOP
  bool _sif1(IopDmaChannel c) {
    final f = sif.sif1Fifo;
    if (c.chcr & (_chain | _tagMode) == 0) {
      var left = _words(c);
      while (left > 0 && f.isNotEmpty) {
        memory.write32(c.madr, f.removeFirst());
        c.madr += 4;
        left--;
      }
      c.bcr = (c.bcr & ~0xffff) | (left & 0xffff);
      return left == 0;
    }
    while (true) {
      if (_sif1Left == 0 && !_sif1End) {
        if (f.length < 4) return false;
        final w0 = f.removeFirst(), w1 = f.removeFirst();
        f.removeFirst();
        f.removeFirst();
        _sif1Address = w0 & 0xffffff;
        _sif1End = (w0 >>> 31) & 1 != 0;
        _sif1Left = w1;
        _sif1Pad = (4 - (w1 & 3)) & 3;
      }
      while (_sif1Left > 0) {
        // data is padded to quadwords
        if (f.length < _sif1Left + _sif1Pad) return false;
        memory.write32(_sif1Address, f.removeFirst());
        _sif1Address += 4;
        _sif1Left--;
        if (_sif1Left == 0) {
          for (var i = 0; i < _sif1Pad; i++) {
            f.removeFirst();
          }
        }
      }
      if (_sif1End) {
        _sif1End = false;
        return true;
      }
    }
  }

  /// SIF0: IOP to EE. Chain tags live in IOP memory at TADR as four words:
  /// address | flags, word count, and the EE tag.
  bool _sif0(IopDmaChannel c) {
    final f = sif.sif0Fifo;
    void pushWords(int address, int count) {
      for (var i = 0; i < count; i++) {
        f.add(memory.read32(address + i * 4));
      }
      for (var i = 0; i < ((4 - (count & 3)) & 3); i++) {
        f.add(0);
      }
    }

    if (c.chcr & (_chain | _tagMode) == 0) {
      pushWords(c.madr, _words(c));
      return true;
    }
    for (var n = 0; n < 0x10000; n++) {
      final w0 = memory.read32(c.tadr), w1 = memory.read32(c.tadr + 4);
      f
        ..add(memory.read32(c.tadr + 8))
        ..add(memory.read32(c.tadr + 12))
        ..add(0)
        ..add(0);
      pushWords(w0 & 0xffffff, w1);
      c.tadr += 16;
      if ((w0 >>> 31) & 1 != 0) break;
    }
    return true;
  }

  int _cdvdLeft = -1; // bytes left in the transfer, or -1 when none started

  /// CDVD DMA: channel 3 moves the sectors read by the drive to memory
  bool _cdvdIn(IopDmaChannel c) {
    if (_cdvdLeft < 0) _cdvdLeft = _words(c) * 4;
    while (_cdvdLeft > 0 && cdvd.dataAvailable) {
      final bytes = cdvd.takeData(_cdvdLeft);
      for (var i = 0; i < bytes.length; i++) {
        memory.write8(c.madr + i, bytes[i]);
      }
      c.madr += bytes.length;
      _cdvdLeft -= bytes.length;
    }
    if (_cdvdLeft > 0) return false;
    _cdvdLeft = -1;
    return true;
  }

  /// SIO2 DMA: channel 11 sends command bytes, channel 12 receives replies
  bool _sio2In(IopDmaChannel c) {
    for (var i = 0; i < _words(c) * 4; i++) {
      sio2.send(memory.read8(c.madr + i));
    }
    return true;
  }

  bool _sio2Out(IopDmaChannel c) {
    for (var i = 0; i < _words(c) * 4; i++) {
      memory.write8(c.madr + i, sio2.receive());
    }
    return true;
  }

  // ---- timers ----

  static const _timerBases = [
    0x1f801100,
    0x1f801110,
    0x1f801120,
    0x1f801480,
    0x1f801490,
    0x1f8014a0
  ];
  static const _timerIrq = [
    IopIrq.timer0,
    IopIrq.timer1,
    IopIrq.timer2,
    IopIrq.timer3,
    IopIrq.timer4,
    IopIrq.timer5
  ];

  static int _timerOf(int address) {
    final i = _timerBases.indexOf(address & ~0xf);
    return i;
  }

  bool _is32(int t) => t >= 3;

  int _timerRead(int t, int offset) {
    switch (offset) {
      case 0:
        return _timerCount[t];
      case 4:
        final v = _timerMode[t];
        _timerMode[t] &= ~0x1800; // reading clears the reached flags
        return v;
      case 8:
        return _timerTarget[t];
    }
    return 0;
  }

  void _timerWrite(int t, int offset, int value) {
    switch (offset) {
      case 0:
        _timerCount[t] = value & (_is32(t) ? 0xffffffff : 0xffff);
      case 4:
        _timerMode[t] = (value & 0x3ff) | 0x400; // bit 10: no interrupt
        _timerCount[t] = 0;
        _timerFraction[t] = 0;
      case 8:
        _timerTarget[t] = value & (_is32(t) ? 0xffffffff : 0xffff);
    }
  }

  /// advances the timers by [clocks] IOP clocks. Timer 1 with clock source
  /// bit 8 counts scanlines instead (see [hblank]); timer 0 with bit 8 would
  /// count the dot clock, which is not modelled and counts system clocks.
  void advanceTimers(int clocks) {
    cdvd.advance(clocks);
    for (var t = 0; t < 6; t++) {
      final mode = _timerMode[t];
      if (t == 1 && (mode >> 8) & 1 != 0) continue;
      var divisor = 1;
      if (t == 2 && (mode >> 9) & 1 != 0) divisor = 8;
      _timerFraction[t] += clocks;
      final ticks = _timerFraction[t] ~/ divisor;
      _timerFraction[t] -= ticks * divisor;
      if (ticks != 0) _tick(t, ticks);
    }
  }

  /// the end of a scanline
  void hblank() {
    if ((_timerMode[1] >> 8) & 1 != 0) _tick(1, 1);
  }

  void _tick(int t, int ticks) {
    final mode = _timerMode[t];
    final limit = _is32(t) ? 0x100000000 : 0x10000;
    var count = _timerCount[t] + ticks;
    final target = _timerTarget[t];
    final passedTarget = _timerCount[t] < target && count >= target;
    if (passedTarget) {
      _timerMode[t] |= 0x800;
      if (mode & 0x10 != 0) raise(_timerIrq[t]);
      if (mode & 8 != 0) count = count - target;
    }
    if (count >= limit) {
      count %= limit;
      _timerMode[t] |= 0x1000;
      if (mode & 0x20 != 0) raise(_timerIrq[t]);
    }
    _timerCount[t] = count;
  }
}
