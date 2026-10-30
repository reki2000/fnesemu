import '../sif.dart';
import '../state.dart';
import 'cdvd.dart';
import 'iop_memory.dart';
import 'ohci.dart';
import 'sio2.dart';
import 'spu2.dart';

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
/// and the SIF mailbox, and the devices on the IOP bus. Other addresses read
/// back what was written.
///
/// DMA interrupts follow ps2tek. A channel flag rises only when its mask bit is set, and DICR.31 is DICR.15 or DICR.23 with any flag of DICR or DICR2. An IRQ tag of the SIF channels sets their DICR2 flag when bit 9 or 10 of DICR2 is set, whatever the mask. DMACEN disables every channel, and DMACINTEN disables the channel interrupts (bit 0 clear) or IRQ 3 (bit 1 set). Their reset values are not documented; they start enabled. DPCR starts at 0x07777777.
///
/// Timers follow ps2tek: an interrupt needs mode bit 10, which a non-repeating timer clears when it interrupts and a repeating one in LEVL mode toggles. Bit 8 selects the 13.5 MHz pixel clock for timer 0 and the horizontal blank for timers 1 and 3. Timer 2 divides by 8, and timers 4 and 5 by 8, 16 or 256. The gates (mode bits 0-2) are not implemented.
///
/// Uncertain details (to be checked against hardware tests): the SIF packet tags.
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
  final spu2 = Spu2();
  final ohci = Ohci();

  int stat = 0, mask = 0, ctrl = 0;
  final channels = List.generate(_channelCount, (_) => IopDmaChannel());
  int dpcr = 0x07777777, dicr = 0, dpcr2 = 0, dicr2 = 0;
  int dmacen = 1, dmacinten = 1;

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
    sio2.onInterrupt = () {
      // the receive DMA that waits for the replies ends before the interrupt
      if (channels[12].chcr & _start != 0) _runChannel(12);
      raise(IopIrq.sio2);
    };
    cdvd.onInterrupt = () => raise(IopIrq.cdvd);
    spu2.onInterrupt = () => raise(IopIrq.spu2);
    dmaHandlers[4] = (c) => _spu2Dma(0, c);
    dmaHandlers[7] = (c) => _spu2Dma(1, c);
    dmaHandlers[3] = _cdvdIn;
    dmaHandlers[11] = _sio2In;
    dmaHandlers[12] = _sio2Out;
    dmaHandlers[9] = _sif0;
    dmaHandlers[10] = _sif1;
  }

  bool get asserted => ctrl != 0 && (stat & mask) != 0;

  /// Saves the registers and the devices on the IOP bus. The SIF belongs to
  /// the EE side.
  void saveState(StateWriter w) {
    w.section('iop io');
    w.ints([
      stat, mask, ctrl, dpcr, dicr, dpcr2, dicr2, _sif1Left, _sif1Address, //
      _sif1Pad, _cdvdLeft, _pendingClocks, _quietClocks, ..._spu2Left,
      dmacen, dmacinten,
    ]);
    w.boolean(_sif1End);
    w.boolean(_sif1Irq);
    for (final c in channels) {
      w.ints([c.madr, c.bcr, c.chcr, c.tadr]);
    }
    for (final list in [
      _timerCount, _timerMode, _timerTarget, //
      _timerFraction
    ]) {
      w.ints(list);
    }
    w.ints([
      for (final e in _backing.entries) ...[e.key, e.value]
    ]);
    cdvd.saveState(w);
    sio2.saveState(w);
    spu2.saveState(w);
    ohci.saveState(w);
  }

  void loadState(StateReader s) {
    s.section('iop io');
    final v = s.fields(17, 'iop io');
    dmacen = v[15];
    dmacinten = v[16];
    stat = v[0];
    mask = v[1];
    ctrl = v[2];
    dpcr = v[3];
    dicr = v[4];
    dpcr2 = v[5];
    dicr2 = v[6];
    _sif1Left = v[7];
    _sif1Address = v[8];
    _sif1Pad = v[9];
    _cdvdLeft = v[10];
    _pendingClocks = v[11];
    _quietClocks = v[12];
    _spu2Left[0] = v[13];
    _spu2Left[1] = v[14];
    _sif1End = s.boolean();
    _sif1Irq = s.boolean();
    for (final c in channels) {
      final r = s.fields(4, 'iop dma channel');
      c.madr = r[0];
      c.bcr = r[1];
      c.chcr = r[2];
      c.tadr = r[3];
    }
    for (final list in [
      _timerCount, _timerMode, _timerTarget, //
      _timerFraction
    ]) {
      s.intsInto(list);
    }
    final b = s.ints();
    _backing.clear();
    for (var i = 0; i + 1 < b.length; i += 2) {
      _backing[b[i]] = b[i + 1];
    }
    cdvd.loadState(s);
    sio2.loadState(s);
    spu2.loadState(s);
    ohci.loadState(s);
    dirty = true;
  }

  void raise(int irq) {
    stat |= 1 << irq;
    dirty = true;
  }

  // ---- registers ----

  /// true for the 32-bit registers that byte and halfword accesses reach
  /// as a part of the aligned word
  static bool _isWordRegister(int address) {
    final a = address & ~3;
    return a == 0x1f801070 ||
        a == 0x1f801074 ||
        a == 0x1f8010f0 ||
        a == 0x1f8010f4 ||
        a == 0x1f801570 ||
        a == 0x1f801574 ||
        a == 0x1f801578 ||
        a == 0x1f80157c ||
        _channelOf(a) >= 0;
  }

  @override
  int read(int address, int size) {
    if (address & 3 != 0 && size < 4 && _isWordRegister(address)) {
      return _readRegister(address & ~3, 4) >>> ((address & 3) * 8);
    }
    return _readRegister(address, size);
  }

  int _readRegister(int address, int size) {
    if (address >= 0x1d000000 && address < 0x1d000100) {
      return sif.iopRead(address & 0xff);
    }
    if (Cdvd.handles(address)) return cdvd.read(address);
    if (Sio2.handles(address)) return sio2.read(address, size);
    if (Spu2.handles(address)) return spu2.read(address, size);
    if (Ohci.handles(address)) return ohci.read(address);
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
        return (dicr & 0x7fffffff) | (_dmaMaster ? 0x80000000 : 0);
      case 0x1f801570:
        return dpcr2;
      case 0x1f801574:
        return dicr2;
      case 0x1f801578:
        return dmacen;
      case 0x1f80157c:
        return dmacinten;
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
    var v = 0;
    for (var i = size - 1; i >= 0; i--) {
      v = (v << 8) | (_backing[address + i] ?? 0);
    }
    return v;
  }

  @override
  void write(int address, int size, int value) {
    if (size < 4 && _isWordRegister(address)) {
      final aligned = address & ~3;
      final shift = (address & 3) * 8;
      final mask = (size == 1 ? 0xff : 0xffff) << shift;
      // the bytes not written keep their value: ones for the acknowledge of
      // I_STAT and zeros for the flags of DICR, which a written 1 clears
      final old = switch (aligned) {
        0x1f801070 => 0xffffffff,
        0x1f8010f4 => dicr & 0x00ffffff,
        0x1f801574 => dicr2 & 0x00ffffff,
        _ => _readRegister(aligned, 4),
      };
      _writeRegister(aligned, 4, (old & ~mask) | ((value << shift) & mask));
      return;
    }
    _writeRegister(address, size, value);
  }

  void _writeRegister(int address, int size, int value) {
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
    if (Spu2.handles(address)) {
      spu2.write(address, size, value);
      return;
    }
    if (Ohci.handles(address)) {
      ohci.write(address, value);
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
        final was = _dmaMaster;
        dicr = _dicrWrite(dicr, value, 0x7f);
        _masterRose(was);
        return;
      case 0x1f801570:
        dpcr2 = value;
        service();
        return;
      case 0x1f801574:
        final was = _dmaMaster;
        dicr2 = _dicrWrite(dicr2, value, 0x3f);
        _masterRose(was);
        return;
      case 0x1f801578:
        dmacen = value & 1;
        service();
        return;
      case 0x1f80157c:
        final was = _dmaMaster;
        dmacinten = value & 3;
        _masterRose(was);
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
          // a new CDVD transfer takes its size from the new BCR
          if (ch == 3 && value & _start != 0) _cdvdLeft = -1;
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

  bool _enabled(int ch) =>
      dmacen & 1 != 0 &&
      (ch < 7
          ? (dpcr >> (ch * 4 + 3)) & 1 != 0
          : (dpcr2 >> ((ch - 7) * 4 + 3)) & 1 != 0);

  /// DICR.31: the bus error flag, or the master enable with any channel
  /// flag of DICR or DICR2; DMACINTEN bit 0 leaves only the bus error
  bool get _dmaMaster {
    if (dicr & 0x8000 != 0) return true;
    if (dmacinten & 1 == 0 || dicr & (1 << 23) == 0) return false;
    return (dicr >> 24) & 0x7f != 0 || (dicr2 >> 24) & 0x3f != 0;
  }

  /// writes DICR or DICR2: a 1 clears a flag of [flagMask]
  int _dicrWrite(int old, int v, int flagMask) {
    final flags = (old >> 24) & flagMask & ~((v >> 24) & flagMask);
    final next = (v & 0x00ffffff) | (flags << 24);
    dirty = true;
    return next;
  }

  /// raises IRQ 3 when a register write set the master flag of DICR, so
  /// that a flag that rose while the interrupt was disabled is delivered
  void _masterRose(bool was) {
    if (!was && _dmaMaster && dmacinten & 2 == 0) raise(IopIrq.dma);
  }

  /// sets the DICR or DICR2 flag of channel [ch] and raises IRQ 3 when the
  /// master flag is set
  void _flag(int ch) {
    if (ch < 7) {
      dicr |= 1 << (24 + ch);
    } else {
      dicr2 |= 1 << (24 + ch - 7);
    }
    if (_dmaMaster && dmacinten & 2 == 0) raise(IopIrq.dma);
  }

  /// an IRQ tag of channel [ch] finished; DICR2 bits 0-12 enable it
  void _tagIrq(int ch) {
    if ((dicr2 >> ch) & 1 != 0) _flag(ch);
  }

  void _complete(int ch) {
    final c = channels[ch];
    c.chcr &= ~_start;
    final enabled = ch < 7
        ? (dicr >> (16 + ch)) & 1 != 0
        : (dicr2 >> (16 + ch - 7)) & 1 != 0;
    if (enabled) _flag(ch);
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
  bool _sif1End = false, _sif1Irq = false;

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
        _sif1Irq = (w0 >>> 30) & 1 != 0;
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
      if (_sif1Irq) {
        _sif1Irq = false;
        _tagIrq(10);
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
      if ((w0 >>> 30) & 1 != 0) _tagIrq(9);
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

  /// SIO2 DMA: channel 11 sends command bytes, channel 12 receives replies.
  /// Every block holds one command or its reply, at the start of the block
  /// (as the memory card driver lays out its buffers).
  bool _sio2In(IopDmaChannel c) {
    final size = (c.bcr & 0xffff) * 4, count = (c.bcr >>> 16) & 0xffff;
    for (var b = 0; b < (count == 0 ? 1 : count); b++) {
      sio2.sendBlock([
        for (var i = 0; i < size; i++) memory.read8(c.madr + b * size + i),
      ]);
    }
    return true;
  }

  bool _sio2Out(IopDmaChannel c) {
    if (!sio2.replyReady) return false;
    final size = (c.bcr & 0xffff) * 4, count = (c.bcr >>> 16) & 0xffff;
    final replies = sio2.replies;
    if (count > 1 && replies.length == count) {
      for (var b = 0; b < count; b++) {
        final reply = replies[b];
        for (var i = 0; i < reply.length && i < size; i++) {
          memory.write8(c.madr + b * size + i, reply[i]);
        }
      }
      sio2.clearReplies();
      return true;
    }
    sio2.replyReady = false;
    for (var i = 0; i < _words(c) * 4; i++) {
      memory.write8(c.madr + i, sio2.receive());
    }
    return true;
  }

  final _spu2Left = [-1, -1]; // halfwords left in an AutoDMA transfer

  /// SPU2 DMA: channel 4 serves core 0 and channel 7 core 1. CHCR bit 0 set
  /// writes to the SPU2. With AutoDMA the blocks of 512 halfwords go to the
  /// input buffer as fast as the core plays them.
  bool _spu2Dma(int core, IopDmaChannel c) {
    if (c.chcr & 1 == 0) {
      for (var i = 0; i < _words(c) * 2; i++) {
        memory.write16(c.madr, spu2.readTransfer(core));
        c.madr += 2;
      }
      return true;
    }
    if (!spu2.autoDma(core)) {
      for (var i = 0; i < _words(c) * 2; i++) {
        spu2.writeTransfer(core, memory.read16(c.madr));
        c.madr += 2;
      }
      return true;
    }
    if (_spu2Left[core] < 0) _spu2Left[core] = _words(c) * 2;
    while (_spu2Left[core] >= 512 && spu2.admaWants(core)) {
      spu2.admaBlock(core, [
        for (var i = 0; i < 512; i++) memory.read16(c.madr + i * 2),
      ]);
      c.madr += 1024;
      _spu2Left[core] -= 512;
    }
    if (_spu2Left[core] >= 512) return false;
    _spu2Left[core] = -1;
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
    _flushTimers();
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
    _flushTimers();
    switch (offset) {
      case 0:
        _timerCount[t] = value & (_is32(t) ? 0xffffffff : 0xffff);
      case 4:
        // a write enables the interrupt (bit 10) and resets the count
        _timerMode[t] = (value & (t >= 4 ? 0x63ff : 0x3ff)) | 0x400;
        _timerCount[t] = 0;
        _timerFraction[t] = 0;
      case 8:
        _timerTarget[t] = value & (_is32(t) ? 0xffffffff : 0xffff);
        if (_timerMode[t] & 0x80 == 0) _timerMode[t] |= 0x400;
    }
    _quietClocks = _timerQuiet();
  }

  // The timers take the clocks lazily. [_pendingClocks] collects them until
  // they reach [_quietClocks], the clocks before the first timer could reach
  // its target or overflow, or until a timer register is accessed. The
  // counts and the interrupts are the same as with an update on every call.
  int _pendingClocks = 0, _quietClocks = 0;

  /// true when timer [t] counts horizontal blanks instead of clocks
  bool _countsLines(int t) =>
      (t == 1 || t == 3) && (_timerMode[t] >> 8) & 1 != 0;

  /// The rate of timer [t] as ticks per IOP clock, numerator and
  /// denominator. Timer 0 with bit 8 counts the 13.5 MHz pixel clock
  /// (1125 / 3072 of the 36.864 MHz IOP clock).
  (int, int) _rate(int t) {
    final mode = _timerMode[t];
    if (t == 0 && (mode >> 8) & 1 != 0) return (1125, 3072);
    if (t == 2 && (mode >> 9) & 1 != 0) return (1, 8);
    if (t >= 4) return (1, const [1, 8, 16, 256][(mode >> 13) & 3]);
    return (1, 1);
  }

  /// advances the timers by [clocks] IOP clocks. Timers 1 and 3 with clock
  /// source bit 8 count scanlines instead (see [hblank]).
  void advanceTimers(int clocks) {
    cdvd.advance(clocks);
    spu2.advance(clocks);
    _pendingClocks += clocks;
    if (_pendingClocks >= _quietClocks) _flushTimers();
  }

  void _flushTimers() {
    final clocks = _pendingClocks;
    _pendingClocks = 0;
    if (clocks != 0) {
      for (var t = 0; t < 6; t++) {
        if (_countsLines(t)) continue;
        final (num, den) = _rate(t);
        _timerFraction[t] += clocks * num;
        final ticks = _timerFraction[t] ~/ den;
        _timerFraction[t] -= ticks * den;
        if (ticks != 0) _tick(t, ticks);
      }
    }
    _quietClocks = _timerQuiet();
  }

  /// the clocks before the first timer that counts clocks reaches its target
  /// or overflows
  int _timerQuiet() {
    var quiet = 1 << 40;
    for (var t = 0; t < 6; t++) {
      if (_countsLines(t)) continue;
      final (num, den) = _rate(t);
      final count = _timerCount[t], target = _timerTarget[t];
      var ticks = (_is32(t) ? 0x100000000 : 0x10000) - count;
      if (count < target && target - count < ticks) ticks = target - count;
      final clocks = (ticks * den - _timerFraction[t] + num - 1) ~/ num;
      if (clocks < quiet) quiet = clocks;
    }
    return quiet;
  }

  /// the end of a scanline
  void hblank() {
    // the clock timers leave out timers 1 and 3 in this mode
    if (_countsLines(1)) _tick(1, 1);
    if (_countsLines(3)) _tick(3, 1);
  }

  void _tick(int t, int ticks) {
    final mode = _timerMode[t];
    final limit = _is32(t) ? 0x100000000 : 0x10000;
    var count = _timerCount[t] + ticks;
    final target = _timerTarget[t];
    final passedTarget = _timerCount[t] < target && count >= target;
    if (passedTarget) {
      _timerEvent(t, 0x800, mode & 0x10 != 0);
      if (mode & 8 != 0) count = count - target;
    }
    if (count >= limit) {
      count %= limit;
      _timerEvent(t, 0x1000, mode & 0x20 != 0);
    }
    _timerCount[t] = count;
  }

  /// Sets the reached [flag] of timer [t] and interrupts when [enabled] and
  /// mode bit 10 allow it. Without repeat (bit 6) the interrupt clears bit
  /// 10. With repeat and LEVL (bit 7) every event toggles bit 10, so every
  /// other event interrupts.
  void _timerEvent(int t, int flag, bool enabled) {
    _timerMode[t] |= flag;
    final mode = _timerMode[t];
    if (!enabled) return;
    final on = mode & 0x400 != 0;
    if (mode & 0xc0 == 0xc0) {
      _timerMode[t] ^= 0x400;
    } else if (on && mode & 0x40 == 0) {
      _timerMode[t] &= ~0x400;
    }
    if (on) raise(_timerIrq[t]);
  }
}
