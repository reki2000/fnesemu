import 'package:fnesemu/core/md/m68/op_0.dart';
import 'package:fnesemu/core/md/m68/op_c.dart';
import 'package:fnesemu/util/int.dart';

import '../bus_m68.dart';

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

  int get ccr => sr & 0xff;
  int get usp => sf ? _usp : a[7];
  set usp(int v) => sf ? _usp = v : a[7] = _usp = v;

  int get ssp => sf ? a[7] : _ssp;
  set ssp(int v) => sf ? a[7] = _ssp = v : _ssp = v;

  int preDec(int reg, int size) {
    clocks += 2;
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
  set sf(bool on) {
    _sr = on ? _sr | bitS : _sr & ~bitS;
    if (on) {
      _usp = a[7];
      a[7] = _ssp;
    } else {
      _ssp = a[7];
      a[7] = _usp;
    }
  }

  int get sr => _sr;
  set sr(int val) {
    _sr = val.mask32;
    sf = val & bitS != 0;
  }

  set tf(bool on) => sr = on ? sr | bitT : sr & ~bitT;

  M68(this.bus);

  bool exec() {
    final op = pc16();

    switch (op >> 12) {
      case 0x00:
        return exec0(op);
      case 0x01:
      case 0x02:
      case 0x03:
        return exec3(op);
      case 0x04:
        return exec4(op);
      case 0x05:
        return exec5(op);
      case 0x06:
        return exec6(op);
      case 0x07:
        return exec7(op);
      case 0x08:
        return exec8(op);
      case 0x09:
        return exec9(op);
      case 0x0a:
        return execA(op);
      case 0x0b:
        return execB(op);
      case 0x0c:
        return execC(op);
      case 0x0d:
        return execD(op);
      case 0x0e:
        return execE(op);
      case 0x0f:
        return execF(op);
    }

    return false;
  }

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
    final d0 = bus.read(addr.mask24);
    final d1 = bus.read(addr.inc.mask24);
    clocks += 4;
    return d0 << 8 | d1;
  }

  void write16(int addr, int data) {
    clocks += 4;
    bus.write(addr.mask24, data.mask8);
    bus.write(addr.inc.mask24, data >> 8 & 0xff);
  }

  int read32(int addr) {
    final d01 = read16(addr);
    final d23 = read16(addr + 2);
    return d01 << 16 | d23;
  }

  void write32(int addr, int data) {
    write16(addr, data >> 16);
    write16(addr + 2, data);
  }

  int read(int addr, int size) {
    return switch (size) {
      1 => read8(addr0),
      2 => read16(addr0),
      4 => read32(addr0),
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
    final d = read16(pc);
    pc = (pc + 2).mask32;
    return d;
  }

  int pc32() {
    final d = read32(pc);
    pc = (pc + 4).mask32;
    return d;
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
    print(
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
        if (reg == 4) return immed(size);
    }

    addr0 = addressing(size, mod, reg);

    return read(addr0, size);
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
}
