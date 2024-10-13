import 'package:fnesemu/core/md/m68/op_0.dart';
import 'package:fnesemu/util/int.dart';

import '../bus_m68.dart';

class M68 {
  BusM68 bus;

  int clocks = 0;
  int cycles = 0;

  // registers
  final a = [0, 0, 0, 0, 0, 0, 0, 0];
  final d = [0, 0, 0, 0, 0, 0, 0, 0];
  int pc = 0;
  int usp = 0;
  int ssp = 0;
  int sr = 0;

  int get ccr => sr & 0xff;

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

  bool get cf => sr & bitC != 0;
  bool get vf => sr & bitV != 0;
  bool get zf => sr & bitZ != 0;
  bool get nf => sr & bitN != 0;
  bool get xf => sr & bitX != 0;

  bool get i0f => sr & bitI0 != 0;
  bool get i1f => sr & bitI1 != 0;
  bool get i2f => sr & bitI2 != 0;
  bool get sf => sr & bitS != 0;
  bool get tf => sr & bitT != 0;

  set cf(bool on) => sr = on ? sr | bitC : sr & ~bitC;
  set vf(bool on) => sr = on ? sr | bitV : sr & ~bitV;
  set zf(bool on) => sr = on ? sr | bitZ : sr & ~bitZ;
  set nf(bool on) => sr = on ? sr | bitN : sr & ~bitN;
  set xf(bool on) => sr = on ? sr | bitX : sr & ~bitX;

  set i0f(bool on) => sr = on ? sr | bitI0 : sr & ~bitI0;
  set i1f(bool on) => sr = on ? sr | bitI1 : sr & ~bitI1;
  set i2f(bool on) => sr = on ? sr | bitI2 : sr & ~bitI2;
  set sf(bool on) => sr = on ? sr | bitS : sr & ~bitS;
  set tf(bool on) => sr = on ? sr | bitT : sr & ~bitT;

  void setSZ(int val) {
    zf = val == 0;
    nf = val & 0x80000000 != 0;
  }

  M68(this.bus);

  bool exec() {
    final op = pc16();

    switch (op >> 12) {
      case 0x00: // alu
        return exec0(op);
      case 0x01: // move
      case 0x02: // move
      case 0x03: // move
        return exec3(op);
      case 0x04: // move
        return exec4(op);
      case 0x05: // move
        return exec5(op);
      case 0x06: // move
        return exec6(op);
      case 0x07: // moveq
        return exec7(op);
      case 0x08: // dbcc
        return exec8(op);
      case 0x09: // scc
        return exec9(op);
      case 0x0a: // trap
        return execA(op);
      case 0x0b: // trap
        return execB(op);
      case 0x0c: // bcc
        return execC(op);
      case 0x0d: // bcc
        return execD(op);
      case 0x0e: // bcc
        return execE(op);
    }

    return false;
  }

  int read(int addr) => bus.read(addr);
  void write(int addr, int data) => bus.write(addr, data);

  int input(int port) => bus.input(port);
  void output(int port, int data) => bus.output(port, data);

  int read16(int addr) {
    final d0 = read(addr);
    final d1 = read(addr + 1);
    return d0 << 8 | d1;
  }

  int read32(int addr) {
    final d0 = read(addr);
    final d1 = read(addr + 1);
    final d2 = read(pc + 2);
    final d3 = read(pc + 3);
    return d0 << 24 | d1 << 16 | d2 << 8 | d3;
  }

  int pc8() {
    final d = read(pc);
    pc = pc.inc.mask32;
    return d;
  }

  int pc16() {
    final d = read16(pc);
    pc = (pc + 2).mask32;
    return d;
  }

  int pc32() {
    final d = read16(pc);
    pc = (pc + 4).mask32;
    return d;
  }

  int addr(int mod, int reg, int reg2, int disp) {
    return switch (mod) {
      2 => a[reg],
      3 => a[reg]++,
      4 => --a[reg],
      5 => a[reg] + disp,
      6 => a[reg] + d[reg2] + disp,
      7 => switch (reg) {
          2 => pc + disp,
          3 => pc + d[reg2] + disp,
          _ => throw ("unreachable"),
        },
      _ => throw ("unreachable"),
    };
  }

  int readAddr(int size, int mod, int reg, int reg2, int disp, int immed) {
    switch (mod) {
      case 0:
        return d[reg];
      case 1:
        return a[reg];
      case 2:
        if (reg == 7) return immed;
        if (reg == 0) return read16(immed);
        if (reg == 1) return read32(immed);
    }

    final addr_ = addr(mod, reg, reg2, disp);

    return switch (size) {
      0 => read(addr_),
      1 => read16(addr_),
      2 => read32(addr_),
      _ => throw ("unreachable"),
    };
  }

  void writeAddr(int size, int mod, int reg, int reg2, int disp, int data) {
    switch (mod) {
      case 0:
        switch (size) {
          case 0:
            d[reg] = d[reg].setL8(data.mask8);
            return;
          case 1:
            d[reg] = d[reg].setL16(data.mask16);
            return;
          case 2:
            d[reg] = data;
            return;
        }
        throw ("unreachable");
      case 1:
        a[reg] = data;
        return;
    }

    final addr_ = addr(mod, reg, reg2, disp);

    switch (size) {
      case 0:
        write(addr_, data);
      case 1:
        write(addr_, data >> 8);
        write(addr_ + 1, data);
      case 2:
        write(addr_, data >> 24);
        write(addr_ + 1, data >> 16);
        write(addr_ + 2, data >> 8);
        write(addr_ + 3, data);
    }
  }
}
