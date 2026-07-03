import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';

import 'apu.dart';
import 'cart.dart';
import 'dma.dart';
import 'irq.dart';
import 'pad.dart';
import 'timer.dart';

/// GBA memory bus. Wires the address-space regions, on-chip RAM and the I/O
/// register file. I/O is dispatched at 16-bit granularity (the natural register
/// width); byte and word accesses are derived from it.
class Bus {
  final pad = Pad();
  Cart cart = Cart();

  late final Irq irq;
  late final Timers timers;
  late final Dma dma;
  late final Apu apu;

  Bus() {
    irq = Irq();
    timers = Timers(irq);
    dma = Dma(this, irq);
    apu = Apu(this);
    timers.onOverflow = apu.onTimerOverflow;
  }

  // on-chip memory
  final bios = Uint8List(0x4000); // 16KB BIOS (loaded externally; HLE later)
  final ewram = Uint8List(0x40000); // 256KB external work RAM
  final iwram = Uint8List(0x8000); // 32KB internal work RAM
  final paletteRam = Uint8List(0x400); // 1KB
  final vram = Uint8List(0x18000); // 96KB
  final oam = Uint8List(0x400); // 1KB

  // raw I/O register backing store (0x4000000..0x40003FE). Registers with side
  // effects are intercepted; the rest reads back the last written value.
  final io = Uint8List(0x400);

  bool biosLoaded = false;

  // display timing, driven by the core's exec loop and read back via DISPSTAT.
  int vcount = 0;
  bool hblank = false;
  bool vblank = false;

  // CPU low-power state set via HALTCNT; cleared when an interrupt is pending.
  bool halted = false;

  void loadBios(Uint8List data) {
    final n = data.length < bios.length ? data.length : bios.length;
    bios.setRange(0, n, data);
    biosLoaded = true;
  }

  void onReset() {
    ewram.fillRange(0, ewram.length, 0);
    iwram.fillRange(0, iwram.length, 0);
    io.fillRange(0, io.length, 0);
    irq.reset();
    timers.reset();
    dma.reset();
    apu.reset();
    vcount = 0;
    hblank = false;
    vblank = false;
    halted = false;
  }

  // --- byte access ----------------------------------------------------------

  int read8(int addr) {
    addr &= 0x0fffffff;
    final region = addr >> 24;
    switch (region) {
      case 0x0:
        return addr < 0x4000 ? bios[addr] : 0;
      case 0x2:
        return ewram[addr & 0x3ffff];
      case 0x3:
        return iwram[addr & 0x7fff];
      case 0x4:
        return _readIo8(addr & 0x3ff);
      case 0x5:
        return paletteRam[addr & 0x3ff];
      case 0x6:
        return vram[_vramOffset(addr)];
      case 0x7:
        return oam[addr & 0x3ff];
      case 0xd:
        if (cart.hasEeprom) return cart.backup.eepromRead();
        return cart.readRom8(addr & 0x01ffffff);
      case 0x8:
      case 0x9:
      case 0xa:
      case 0xb:
      case 0xc:
        return cart.readRom8(addr & 0x01ffffff);
      case 0xe:
      case 0xf:
        return cart.readSram(addr & 0xffff);
      default:
        return 0;
    }
  }

  void write8(int addr, int data) {
    addr &= 0x0fffffff;
    data &= 0xff;
    final region = addr >> 24;
    switch (region) {
      case 0x2:
        ewram[addr & 0x3ffff] = data;
        return;
      case 0x3:
        iwram[addr & 0x7fff] = data;
        return;
      case 0x4:
        _writeIo8(addr & 0x3ff, data);
        return;
      case 0x5:
        // 8-bit writes to palette are mirrored to 16-bit on real HW
        final a = addr & 0x3fe;
        paletteRam[a] = data;
        paletteRam[a + 1] = data;
        return;
      case 0x6:
        final a = _vramOffset(addr) & ~1;
        vram[a] = data;
        vram[a + 1] = data;
        return;
      case 0x7:
        // 8-bit writes to OAM are ignored on real HW
        return;
      case 0xd:
        if (cart.hasEeprom) cart.backup.eepromWrite(data & 1);
        return;
      case 0xe:
      case 0xf:
        cart.writeSram(addr & 0xffff, data);
        return;
      default:
        return;
    }
  }

  // --- 16/32-bit access (little-endian) -------------------------------------

  int read16(int addr) {
    final region = (addr >> 24) & 0xf;
    if (region == 0x4) return _readIo16(addr & 0x3fe);
    // EEPROM is bit-serial: a 16-bit read consumes exactly one bit.
    if (region == 0xd && cart.hasEeprom) return cart.backup.eepromRead();
    return read8(addr) | (read8(addr + 1) << 8);
  }

  int read32(int addr) {
    if ((addr >> 24) & 0xf == 0x4) {
      final r = addr & 0x3fc;
      return _readIo16(r) | (_readIo16(r + 2) << 16);
    }
    return read8(addr) |
        (read8(addr + 1) << 8) |
        (read8(addr + 2) << 16) |
        (read8(addr + 3) << 24);
  }

  // 16/32-bit writes go straight to the backing arrays. They must NOT be
  // decomposed into byte writes: 8-bit writes to palette/VRAM have a mirroring
  // side effect that would corrupt halfword/word stores.
  void write16(int addr, int data) {
    addr &= 0x0fffffff;
    data &= 0xffff;
    switch (addr >> 24) {
      case 0x2:
        _w16(ewram, addr & 0x3fffe, data);
        return;
      case 0x3:
        _w16(iwram, addr & 0x7ffe, data);
        return;
      case 0x4:
        _writeIo16(addr & 0x3fe, data);
        return;
      case 0x5:
        _w16(paletteRam, addr & 0x3fe, data);
        return;
      case 0x6:
        _w16(vram, _vramOffset(addr) & ~1, data);
        return;
      case 0x7:
        _w16(oam, addr & 0x3fe, data);
        return;
      case 0xd:
        if (cart.hasEeprom) cart.backup.eepromWrite(data & 1);
        return;
      case 0xe:
      case 0xf:
        cart.writeSram(addr & 0xffff, data & 0xff);
        return;
      default:
        return; // BIOS / ROM are not writable
    }
  }

  void write32(int addr, int data) {
    if ((addr >> 24) & 0xf == 0x4) {
      final r = (addr & 0x3fc);
      _writeIo16(r, data & 0xffff);
      _writeIo16(r + 2, (data >> 16) & 0xffff);
      return;
    }
    write16(addr & ~3, data & 0xffff);
    write16((addr & ~3) + 2, (data >> 16) & 0xffff);
  }

  void _w16(Uint8List m, int a, int data) {
    m[a] = data & 0xff;
    m[a + 1] = (data >> 8) & 0xff;
  }

  // VRAM is 96KB but mirrored in a 128KB window as 64KB + 32KB + 32KB(mirror).
  int _vramOffset(int addr) {
    var a = addr & 0x1ffff;
    if (a >= 0x18000) a -= 0x8000;
    return a;
  }

  // --- I/O registers --------------------------------------------------------

  static const _dispstat = 0x004;
  static const _vcount = 0x006;
  static const _keyInput = 0x130; // KEYINPUT (read-only)
  static const _ie = 0x200;
  static const _if = 0x202;
  static const _ime = 0x208;
  static const _haltcnt = 0x300; // POSTFLG(0x300) / HALTCNT(0x301)

  // DISPSTAT enable bits / VCount setting, read from the backing store.
  int get _dispstatRaw => io[_dispstat] | (io[_dispstat + 1] << 8);
  bool get vblankIrqEnabled => _dispstatRaw.bit3;
  bool get hblankIrqEnabled => _dispstatRaw.bit4;
  bool get vcountIrqEnabled => _dispstatRaw.bit5;
  int get vcountSetting => _dispstatRaw >> 8;

  void _storeIo(int reg, int data) {
    io[reg] = data & 0xff;
    io[reg + 1] = (data >> 8) & 0xff;
  }

  int _readIo8(int reg) {
    final v = _readIo16(reg & ~1);
    return (reg & 1) == 0 ? v & 0xff : (v >> 8) & 0xff;
  }

  void _writeIo8(int reg, int data) {
    // POSTFLG (0x300) and HALTCNT (0x301) must be distinguished per byte:
    // the BIOS writes POSTFLG=1 during boot with all interrupts disabled, and
    // that write must NOT enter HALT (only a HALTCNT write does).
    if (reg == _haltcnt) {
      io[reg] = data & 0xff;
      return;
    }
    if (reg == _haltcnt + 1) {
      io[reg] = data & 0xff;
      halted = true;
      return;
    }
    final r = reg & ~1;
    final cur = _readIo16(r);
    _writeIo16(r, (reg & 1) == 0 ? cur.setL8(data) : cur.setH8(data));
  }

  static bool _isApuReg(int reg) =>
      (reg >= 0x60 && reg <= 0x84) || (reg >= 0xa0 && reg <= 0xa6);

  int _readIo16(int reg) {
    if (_isApuReg(reg)) return apu.read16(reg);
    if (reg >= 0x0b0 && reg <= 0x0df) return dma.read16(reg);
    if (reg >= 0x100 && reg <= 0x10f) return timers.read16(reg);
    switch (reg) {
      case _dispstat:
        return _readDispstat();
      case _vcount:
        return vcount & 0xff;
      case _keyInput:
        return pad.keyInput;
      case _ie:
        return irq.ie;
      case _if:
        return irq.if_;
      case _ime:
        return irq.ime;
      default:
        return io[reg] | (io[reg + 1] << 8);
    }
  }

  void _writeIo16(int reg, int data) {
    data &= 0xffff;
    if (_isApuReg(reg)) {
      apu.write16(reg, data);
      return;
    }
    if (reg >= 0x0b0 && reg <= 0x0df) {
      dma.write16(reg, data);
      return;
    }
    if (reg >= 0x100 && reg <= 0x10f) {
      timers.write16(reg, data);
      return;
    }
    switch (reg) {
      case _dispstat:
        // status bits 0-2 are read-only; keep only enables + VCount setting
        _storeIo(reg, data & 0xff38);
        return;
      case _vcount:
        return; // read-only
      case _ie:
        irq.ie = data;
        return;
      case _if:
        irq.ack(data); // write 1 to acknowledge/clear
        return;
      case _ime:
        irq.ime = data & 1;
        return;
      case _haltcnt:
        // high byte (0x301) is HALTCNT: any write enters HALT/STOP low-power.
        _storeIo(reg, data);
        halted = true;
        return;
      default:
        _storeIo(reg, data);
        return;
    }
  }

  int _readDispstat() {
    final raw = _dispstatRaw;
    int v = raw & 0xff38; // enable bits + VCount setting
    if (vblank) v |= 1;
    if (hblank) v |= 2;
    if (vcount == (raw >> 8)) v |= 4;
    return v;
  }
}
