import 'package:fnesemu/util/int.dart';

import '../bus_m68.dart';

export 'op.dart';

class BusError implements Exception {
  final bool read;
  final bool inst;
  final int addr;
  final int pc;
  const BusError(this.addr, this.pc, this.read, this.inst);
}

class _AddressReg {
  final a = [0, 0, 0, 0, 0, 0, 0]; // a0 - a6
  int ssp = 0;
  int usp = 0;
  bool sf = false;

  int operator [](int index) => index != 7 ? a[index] : (sf ? ssp : usp);

  void operator []=(int index, int value) =>
      (index != 7) ? a[index] = value : (sf ? ssp = value : usp = value);

  map(Function(int) func) => List.generate(8, (i) => func(this[i]));
}

class M68 {
  BusM68 bus;

  M68(this.bus);

  int clocks = 0;
  // int cycles = 0;

  // registers
  final a = _AddressReg();
  final d = [0, 0, 0, 0, 0, 0, 0, 0];
  int _pc = 0;

  int pc0 = 0; // pc at every instruction
  int op0 = 0;

  int _sr = 0;

  int get pc => _pc;
  set pc(int v) {
    if (v.bit0) {
      throw BusError(v, v.dec4.mask32, true, true);
    } else {
      _pc = v.mask32;
    }
  }

  int get usp => a.usp;
  int get ssp => a.ssp;
  set usp(int v) => a.usp = v;
  set ssp(int v) => a.ssp = v;

  int get ccr => _sr & 0xff;

  int get sr => _sr;
  set sr(int val) {
    sf = (val & bitS) != 0;
    _sr = val & 0xa71f;
  }

  // flags
  static const int bitC = 0x01;
  static const int bitV = 0x02;
  static const int bitZ = 0x04;
  static const int bitN = 0x08;
  static const int bitX = 0x10;

  static const int bitI0 = 0x100;
  static const int bitI1 = 0x200;
  static const int bitI2 = 0x400;
  static const int bitS = 0x2000;
  static const int bitT = 0x8000;

  bool get cf => _sr & bitC != 0;
  bool get vf => _sr & bitV != 0;
  bool get zf => _sr & bitZ != 0;
  bool get nf => _sr & bitN != 0;
  bool get xf => _sr & bitX != 0;

  set cf(bool on) => on ? _sr |= bitC : _sr &= ~bitC;
  set vf(bool on) => on ? _sr |= bitV : _sr &= ~bitV;
  set zf(bool on) => on ? _sr |= bitZ : _sr &= ~bitZ;
  set nf(bool on) => on ? _sr |= bitN : _sr &= ~bitN;
  set xf(bool on) => on ? _sr |= bitX : _sr &= ~bitX;

  int get maskedIntLevel => _sr >> 8 & 0x07;

  bool get sf => _sr & bitS != 0;
  bool get tf => _sr & bitT != 0;

  set sf(bool on) {
    a.sf = on;
    on ? _sr |= bitS : _sr &= ~bitS;
  }

  set tf(bool on) => on ? sr |= bitT : sr &= ~bitT;

  // interrupt
  int assertedIntLevel = 0;

  // memory access
  int read8(int addr) {
    clocks += 4;
    return bus.read8(addr.mask24);
  }

  void write8(int addr, int data) {
    clocks += 4;
    bus.write8(addr.mask24, data.mask8);
  }

  int read16(int addr) {
    clocks += 4;

    if (addr.bit0) {
      throw BusError(addr, _pc.dec2.mask32, true, false);
    }

    return bus.read16(addr.mask24);
  }

  void write16(int addr, int data) {
    clocks += 4;

    if (addr.bit0) {
      throw BusError(addr, _pc, false, false);
    }

    bus.write16(addr.mask24, data);
  }

  int read32(int addr) {
    final d32 = read16(addr);
    final d10 = read16(addr + 2);
    return d32 << 16 | d10;
  }

  void write32(int addr, int data) {
    write16(addr, data >> 16);
    write16(addr.inc2, data);
  }

  int read(int addr, int size) {
    return switch (size) {
      1 => read8(addr),
      2 => read16(addr),
      4 => read32(addr),
      _ => throw ("unreachable"),
    };
  }

  void write(int addr, int size, int data) {
    switch (size) {
      case 1:
        write8(addr, data);
        return;
      case 2:
        write16(addr, data);
        return;
      case 4:
        write32(addr, data);
        return;
      default:
        throw ("unreachable");
    }
  }

  int pc16() {
    clocks += 4;

    final d0 = bus.read16(_pc.mask24);
    _pc = _pc.inc2;
    return d0;
  }

  int pc32() {
    final d01 = pc16();
    final d23 = pc16();
    return d01 << 16 | d23;
  }

  int immed(int size) => switch (size) {
        1 => pc16().mask8,
        2 => pc16(),
        4 => pc32(),
        _ => throw ("unreachable"),
      };

  // "size" to byte length
  final size0 = [1, 2, 4, 0]; // commonly used
  final size1 = [2, 4]; // 1 bit
  final size2 = [0, 1, 4, 2]; // chk, movea, move

  // addressing modes
  int addressing(int size, int mode, int reg) {
    return switch (mode) {
      2 => a[reg],
      3 => a[reg],
      4 => preDec(reg, size),
      5 => a[reg] + pc16().rel16,
      6 => a[reg] + addressingEx(mode),
      7 => switch (reg) {
          0 => pc16().rel16,
          1 => pc32(),
          2 => pc + pc16().rel16,
          3 => pc + addressingEx(mode),
          _ => throw ("unreachable reg:$reg")
        },
      _ => throw ("unreachable mode:$mode"),
    };
  }

  int preDec(int reg, int size) => switch (size) {
        4 => a[reg] = a[reg].dec4.mask32,
        2 => a[reg] = a[reg].dec2.mask32,
        1 when reg == 7 => a[reg] = a[reg].dec2.mask32,
        1 => a[reg] = a[reg].dec.mask32,
        _ => throw ("invalid size:$size"),
      };

  int postInc(int reg, int size) {
    final r = a[reg];

    final _ = switch (size) {
      4 => a[reg] = a[reg].inc4.mask32,
      2 => a[reg] = a[reg].inc2.mask32,
      1 when reg == 7 => a[reg] = a[reg].inc2.mask32,
      1 => a[reg] = a[reg].inc.mask32,
      _ => throw ("invalid size:$size"),
    };

    return r;
  }

  int addressingEx(int mod) {
    clocks += 2;
    final ex = pc16();
    final modeAn = ex.bit15;
    final xn = ex >> 12 & 0x07;
    final size = size1[ex >> 11 & 0x01];
    final x = modeAn ? a[xn] : d[xn];
    final disp = ex.mask8.rel8;
    // debug(
    //     "Ex:${ex.hex16}, ${modeAn ? "A$xn" : "X$xn"}, $size, ${x.hex32}, ${ex.mask8.hex8}");
    return disp + ((size == 2) ? x.mask16.rel16 : x);
  }

  // preserved the address calulated by readAddr, used by writeAddr
  int addr0 = 0;

  int readAddr(int size, int mod, int reg) {
    switch (mod) {
      case 0:
        return d[reg].mask(size);
      case 1:
        return a[reg].mask(size);
      case 7:
        if (reg == 4) {
          return immed(size);
        }
    }

    addr0 = addressing(size, mod, reg);

    if (mod == 3) postInc(reg, size);

    final val = read(addr0, size);
    if (mod == 4) {
      clocks += 2;
    }

    return val;
  }

  void writeAddr(int size, int mod, int reg, int data) {
    switch (mod) {
      case 0:
        d[reg] = d[reg].setL(data, size);
        return;
      case 1:
        a[reg] = a[reg].setL(data, size);
        return;
    }

    write(addr0, size, data);
  }

  void push16(int data) {
    a[7] = a[7].dec2.mask32;
    write16(a[7], data);
  }

  void push32(int data) {
    push16(data);
    push16(data >> 16);
  }

  int pop16() {
    final val = read16(a[7]);
    a[7] = a[7].inc2.mask32;
    return val;
  }

  int pop32() {
    final d01 = pop16();
    final d23 = pop16();
    return d01 << 16 | d23;
  }

  bool cond(int cond) => switch (cond) {
        0x00 => true,
        0x01 => false,
        0x02 => !cf && !zf, // hi
        0x03 => cf || zf, // low or same
        0x04 => !cf, // cc
        0x05 => cf, // cs
        0x06 => !zf, // ne
        0x07 => zf, // eq
        0x08 => !vf, // vc
        0x09 => vf, // vs
        0x0a => !nf, // pl
        0x0b => nf, // mi
        0x0c => (nf && vf) || (!nf && !vf), // ge
        0x0d => (nf && !vf) || (!nf && vf), // lt
        0x0e => !zf && ((nf && vf) || (!nf && !vf)), // gt
        0x0f => zf || (nf && !vf) || (!nf && vf), // le
        _ => throw "invalid cond: $cond",
      };

  void busError(int addr, int pc, int op, bool read, bool inst) {
    // debug(
    //     "bus error: clock:$clocks addr:${addr.hex24} pc:${pc.hex24} op:${op.hex16} read:$read inst:$inst a7:${a[7].hex24} ssp:${_ssp.hex24} usp:${_usp.hex24}"); // +44 clocks
    final fc = (sf ? 0x4 : 0) | (inst ? 0x2 : 0x1);
    sf = true;
    push32(pc); // +8
    push16(sr.mask16); // +4 : +12
    push16(op); // +4 : +16
    push32(addr); // +8 : +24

    push16(
        (read ? 0x10 : 0) | (inst ? 0x08 : 0) | fc | op & 0xffe0); // +4 : +28
    _pc = read32(0x0c); // +8 : 36

    clocks += 8; // 2 prefetch : 44
  }

  void trap(int vector) {
    // debug(
    //     "trap vector:${vector.hex32} pc:${pc.hex32} sr:${sr.hex16} a7:${a[7].hex32} ssp:${_ssp.hex32} usp:${_usp.hex32}");
    final savedSr = sr.mask16;
    sf = true;
    push32(pc); // +8
    push16(savedSr); // +4 : +12
    _pc = read32(vector); // +8 : 32
    clocks += 8; // 2 prefetch : 40
  }

  void reset() {
    // debug("reset");
    sr = 0x2700;
    ssp = read32(0x00);
    _pc = read32(0x04);
    clocks = 0;
    assertedIntLevel = 0;
  }

  String dump() {
    final rega = 'a:${a.map((e) => e.hex32).join(' ')}';
    final regd = 'd:${d.map((e) => e.hex32).join(' ')}';
    final regs =
        'sr:${sr.hex32} usp:${usp.hex32} ssp:${ssp.hex32} pc:${pc.hex32} cl:$clocks';

    const f = "XNZVC";
    final flags = List.generate(
        f.length,
        (i) => "$f${f.toLowerCase()}"[
            (sr << i & (1 << f.length - 1) != 0) ? i : f.length + i]).join();
    return '$regd\n$rega\n$flags $regs';
  }
}
