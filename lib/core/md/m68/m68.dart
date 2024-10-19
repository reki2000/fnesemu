import 'package:fnesemu/util/int.dart';

import '../bus_m68.dart';

class BusError implements Exception {
  final bool read;
  final bool inst;
  final int addr;
  const BusError(this.addr, this.read, this.inst);
}

class M68 {
  BusM68 bus;

  int clocks = 0;
  // int cycles = 0;

  // registers
  final a = [0, 0, 0, 0, 0, 0, 0, 0];
  final d = [0, 0, 0, 0, 0, 0, 0, 0];
  int pc = 0;
  int _usp = 0;
  int _ssp = 0;
  int _sr = 0;

  int get usp => sf ? _usp : a[7];
  set usp(int v) => sf ? (_usp = v) : (a[7] = _usp = v);

  int get ssp => sf ? a[7] : _ssp;
  set ssp(int v) => sf ? (a[7] = _ssp = v) : (_ssp = v);

  int preDec(int reg, int size) {
    if (reg == 7 && size == 1 || size == 2) {
      return a[reg] = a[reg].dec2.mask32;
    } else if (size == 4) {
      return a[reg] = a[reg].dec4.mask32;
    } else {
      return a[reg] = a[reg].dec.mask32;
    }
  }

  int postInc(int reg, int size) {
    final r = a[reg];
    if (reg == 7 && size == 1 || size == 2) {
      a[reg] = a[reg].inc2.mask32;
    } else if (size == 4) {
      a[reg] = a[reg].inc4.mask32;
    } else {
      a[reg] = a[reg].inc.mask32;
    }
    return r;
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

  bool get i0f => _sr & bitI0 != 0;
  bool get i1f => _sr & bitI1 != 0;
  bool get i2f => _sr & bitI2 != 0;
  bool get sf => _sr & bitS != 0;
  bool get tf => _sr & bitT != 0;

  set cf(bool on) => _sr = on ? _sr | bitC : _sr & ~bitC;
  set vf(bool on) => _sr = on ? _sr | bitV : _sr & ~bitV;
  set zf(bool on) => _sr = on ? _sr | bitZ : _sr & ~bitZ;
  set nf(bool on) => _sr = on ? _sr | bitN : _sr & ~bitN;
  set xf(bool on) => _sr = on ? _sr | bitX : _sr & ~bitX;

  set i0f(bool on) => _sr = on ? _sr | bitI0 : _sr & ~bitI0;
  set i1f(bool on) => _sr = on ? _sr | bitI1 : _sr & ~bitI1;
  set i2f(bool on) => _sr = on ? _sr | bitI2 : _sr & ~bitI2;

  // supervisor mode flags switches stack pointer
  set sf(bool on) {
    //   print(
    //       "sf:$sf on:$on _ssp:${_ssp.hex32} _usp:${_usp.hex32} a7:${a[7].hex32}");
    if (!sf && on) {
      _usp = a[7];
      a[7] = _ssp;
      _sr |= bitS;
    } else if (sf && !on) {
      _ssp = a[7];
      a[7] = _usp;
      _sr &= ~bitS;
    }
  }

  int get ccr => _sr & 0xff;

  int get sr => _sr;
  set sr(int val) {
    _sr = val.mask32;
    sf = (val & bitS) != 0;
  }

  set tf(bool on) => sr = on ? sr | bitT : sr & ~bitT;

  M68(this.bus);

  int input(int port) => bus.input(port);
  void output(int port, int data) => bus.output(port, data);

  int read8(int addr) {
    clocks += 4;
    return bus.read(addr.mask24);
  }

  void write8(int addr, int data) {
    clocks += 4;
    bus.write(addr.mask24, data.mask8);
  }

  int read16(int addr) {
    clocks += 4;

    if (addr.bit0) {
      throw BusError(addr, true, false);
    }

    final d0 = bus.read(addr.mask24);
    final d1 = bus.read(addr.inc.mask24);
    return d0 << 8 | d1;
  }

  void write16(int addr, int data) {
    clocks += 4;

    if (addr.bit0) {
      throw BusError(addr, false, false);
    }

    bus.write(addr.mask24, data >> 8 & 0xff);
    bus.write(addr.inc.mask24, data.mask8);
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

    if (pc.bit0) {
      throw BusError(pc, true, true);
    }

    final d0 = bus.read(pc.mask24);
    final d1 = bus.read(pc.inc.mask24);
    pc = (pc + 2).mask32;
    return d0 << 8 | d1;
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

  int addressingEx(int mod) {
    clocks += 2;
    final ex = pc16();
    final modeAn = ex.bit15;
    final xn = ex >> 12 & 0x07;
    final size = size1[ex >> 11 & 0x01];
    final x = modeAn ? a[xn] : d[xn];
    final disp = ex.mask8.rel8;
    debug(
        "Ex:${ex.hex16}, ${modeAn ? "A$xn" : "X$xn"}, $size, ${x.hex32}, ${ex.mask8.hex8}");
    return disp + ((size == 2) ? x.mask16.rel16 : x);
  }

  int addressing(int size, int mode, int reg) {
    return switch (mode) {
      2 => a[reg],
      3 => postInc(reg, size),
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
    a[7] = a[7].dec2.mask32;
    write16(a[7], data);
    a[7] = a[7].dec2.mask32;
    write16(a[7], data >> 16);
  }

  void busError(int addr, int op, bool read, bool inst) {
    debug(
        "bus error: clock:$clocks addr:${addr.hex24} pc:$pc op:${op.hex16} read:$read inst:$inst"); // +44 clocks
    push32(pc.dec2); // +8
    push16(sr.mask16); // +4 : +12
    push16(op); // +4 : +16
    push32(addr); // +8 : +24

    final fc = (sf ? 0x4 : 0) | (inst ? 0x2 : 0x1);
    push16(
        (read ? 0x10 : 0) | (inst ? 0x08 : 0) | fc | op & 0xffe0); // +4 : +28
    pc = read32(0x0c); // +8 : 36
    clocks += 8; // 2 prefetch : 44
  }
}

String debugLog = "";
void debug(args) => debugLog += "$args\n";
