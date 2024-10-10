import 'dart:typed_data';

import 'package:fnesemu/core/md/z80/op_40_bf.dart';
import 'package:fnesemu/core/md/z80/op_c0_ff.dart';
import 'package:fnesemu/core/md/z80/op_cb.dart';
import 'package:fnesemu/core/md/z80/op_ddfd.dart';
import 'package:fnesemu/core/md/z80/op_ed.dart';
import 'package:fnesemu/util.dart';

import '../bus_z80.dart';
import 'op_00_3f.dart';

class Regs {
  List<int> r8 = List.filled(8, 0); // b,c,d,e,h,l,_,a;

  int f = 0;
  int i = 0;
  int r = 0;

  List<int> ixiy = List.filled(2, 0);

  int pc = 0;
  int sp = 0;

  int af2 = 0;
  int bc2 = 0;
  int de2 = 0;
  int hl2 = 0;

  int get b => r8[0];
  set b(int val) => r8[0] = val;

  int get c => r8[1];
  set c(int val) => r8[1] = val;

  int get d => r8[2];
  set d(int val) => r8[2] = val;

  int get e => r8[3];
  set e(int val) => r8[3] = val;

  int get h => r8[4];
  set h(int val) => r8[4] = val;

  int get l => r8[5];
  set l(int val) => r8[5] = val;

  int get a => r8[7];
  set a(int val) => r8[7] = val;

  int get af => (r8[7] << 8) | f;
  set af(int val) {
    r8[7] = val >> 8;
    f = val & 0xff;
  }

  int get bc => (r8[1] << 8) | r8[0];
  set bc(int val) {
    r8[1] = val >> 8;
    r8[0] = val & 0xff;
  }

  int get de => (r8[3] << 8) | r8[2];
  set de(int val) {
    r8[3] = val >> 8;
    r8[2] = val & 0xff;
  }

  int get hl => (r8[5] << 8) | r8[4];
  set hl(int val) {
    r8[5] = val >> 8;
    r8[4] = val & 0xff;
  }

  int get ix => ixiy[0];
  set ix(int val) => ixiy[0] = val;

  int get iy => ixiy[1];
  set iy(int val) => ixiy[1] = val;

  static const S = 0x80;
  bool get flagS => (f & S) != 0;
  set flagS(bool on) => f = S | f & ~S;

  static const Z = 0x40;
  bool get flagZ => (f & Z) != 0;
  set flagZ(bool on) => f = Z | f & ~Z;

  static const H = 0x10;
  bool get flagH => (f & H) != 0;
  set flagH(bool on) => f = H | f & ~H;

  static const P = 0x04;
  static const V = 0x04;
  bool get flagPV => (f & P) != 0;
  set flagPV(bool on) => f = P | f & ~P;

  static const N = 0x02;
  bool get flagN => (f & N) != 0;
  set flagN(bool on) => f = N | f & ~N;

  static const C = 0x01;
  bool get flagC => (f & C) != 0;
  set flagC(bool on) => f = C | f & ~C;

  void setFlagsSZ(int result) {
    f = result & 0x80 | f & ~S;
    flagZ = result == 0;
  }

  void setFlagsV(int src, int dst, int result) {
    flagPV = (src & 0x80) == (dst & 0x80) && (dst & 0x80) != (result & 0x80);
  }

  void setFlagsP(int result) {
    f = (_parity[result >> 4] ^ _parity[result & 0x0f]) | f & ~P;
  }

  int setFlagsC(int result) {
    flagC = result > 0xff || result < 0;
    return result & 0xff;
  }

  static const _parity = [P, 0, 0, P, 0, P, P, 0, 0, P, P, 0, P, 0, 0, P];
}

class Z80 {
  final BusZ80 bus;

  int clocks = 0;
  int cycles = 0;

  var regs = Regs();

  bool iff1 = false;
  bool iff2 = false;
  int im = 0;

  int repMode = repNone; // 1:ld 2:cp 3:in 4:out
  int repDirection = 1; // 1:inc -1:dec
  bool repLoop = false;
  static const repNone = 0;
  static const repLd = 1;
  static const repCp = 2;
  static const repIn = 3;
  static const repOut = 4;

  Z80(this.bus);

  bool exec() {
    // interrupt

    // rep
    if (repMode != repNone) {
      doRep();
      return true;
    }

    final op = pc();

    if (op < 0x40) {
      return exec003f(op);
    }

    if (op < 0xc0) {
      return exec40bf(op);
    }

    return switch (op) {
      0xfd => execDdFd(op, 1),
      0xed => execEd(op),
      0xcb => execCb(op),
      0xdd => execDdFd(op, 0),
      _ => execC0ff(op)
    };
  }

  final ram = Uint8List(0x2000);

  int read(int addr) => bus.read(addr);
  void write(int addr, int data) => bus.write(addr, data);

  void output(int port, int data) {}
  int input(int port) => 0xff;

  int pc() {
    final d = read(regs.pc);
    regs.pc = (regs.pc + 1) & 0xffff;
    return d;
  }

  int pc16() {
    final d0 = read(regs.pc);
    regs.pc = (regs.pc + 1) & 0xffff;
    final d1 = read(regs.pc);
    regs.pc = (regs.pc + 1) & 0xffff;
    return d0 | d1 << 8;
  }

  int rel8() {
    final d = pc();
    return (d & 0x80) != 0 ? d - 0x100 : d;
  }

  int pop() {
    final d = read(regs.sp).withHighByte(read((regs.sp + 1) & 0xffff));
    regs.sp = (regs.sp + 2) & 0xffff;
    return d;
  }

  void push(int d) {
    regs.sp = (regs.sp - 2) & 0xffff;
    write(regs.sp, d >> 8);
    write((regs.sp + 1) & 0xffff, d);
  }

  int readReg(int reg) {
    if (reg == 6) {
      cycles += 3;
      return read(regs.hl);
    } else {
      return regs.r8[reg];
    }
  }

  void writeReg(int reg, int data) {
    if (reg == 6) {
      write(regs.hl, data);
      cycles += 3;
    } else {
      regs.r8[reg] = data;
    }
  }

  int add16(int org, int val, {int c = 0}) {
    final result = (org + val);
    regs.flagH = (org & 0xfff) + (val & 0xfff) > 0xfff;
    regs.flagC = result > 0xffff;
    regs.flagN = false;
    cycles += 11;
    return result & 0xffff;
  }

  int sbc16(int org, int val) {
    final result = org - val - (regs.flagC ? 1 : 0);
    regs.flagH = (org & 0xfff) - (val & 0xfff) - (regs.flagC ? 1 : 0) < 0;
    regs.flagC = result < 0;
    regs.flagN = true;
    cycles += 11;
    return result & 0xffff;
  }

  int inc8(int val) {
    final result = val + 1;
    regs.flagC = result == 0x100;
    regs.setFlagsSZ(result);
    regs.flagPV = result == 0x80;
    regs.flagH = (result & 0x0f) == 0x00;
    regs.flagN = false;
    cycles += 4;
    return result & 0xff;
  }

  int dec8(int val) {
    final result = val - 1;
    regs.flagC = val == 0x00;
    regs.setFlagsSZ(result);
    regs.flagPV = val == 0x80;
    regs.flagH = (val & 0x0f) == 0x00;
    regs.flagN = true;
    cycles += 4;
    return result & 0xff;
  }

  void add8(int val, int c) {
    final result = regs.a + val + c;
    regs.setFlagsSZ(result);
    regs.setFlagsV(regs.a, val, result);
    regs.flagH = (regs.a & 0xf) + (val & 0xf) > 0xf;
    regs.flagN = false;
    regs.flagC = result > 0xff;
    regs.a = result & 0xff;
  }

  void sub8(int val, int c) {
    final result = regs.a - val - c;
    regs.setFlagsSZ(result);
    regs.setFlagsV(regs.a, val, result);
    regs.flagH = (regs.a & 0xf) - (val & 0xf) < 0;
    regs.flagN = true;
    regs.flagC = result < 0;
    regs.a = result & 0xff;
  }

  void and8(int val) {
    regs.a &= val;
    regs.setFlagsSZ(regs.a);
    regs.flagH = true;
    regs.flagN = false;
    regs.flagC = false;
  }

  void or8(int val) {
    regs.a |= val;
    regs.setFlagsSZ(regs.a);
    regs.flagH = false;
    regs.flagN = false;
    regs.flagC = false;
  }

  void xor8(int val) {
    regs.a ^= val;
    regs.setFlagsSZ(regs.a);
    regs.flagH = false;
    regs.flagN = false;
    regs.flagC = false;
  }

  void cp8(int val) {
    final result = regs.a - val;
    regs.setFlagsSZ(result);
    regs.setFlagsV(regs.a, val, result);
    regs.flagH = (regs.a & 0xf) - (val & 0xf) < 0;
    regs.flagN = true;
    regs.flagC = result < 0;
  }

  int rl8(int val) {
    final c = regs.flagC ? 1 : 0;
    regs.flagC = val & 0x80 != 0;
    val = (val << 1) | c;
    regs.setFlagsSZ(val);
    regs.flagH = false;
    regs.flagN = false;
    return val;
  }

  int rlc8(int val) {
    regs.flagC = val & 0x80 != 0;
    val = (val << 1) | (val >> 7);
    regs.setFlagsSZ(val);
    regs.flagH = false;
    regs.flagN = false;
    return val;
  }

  int rr8(int val) {
    final c = regs.flagC ? 0x80 : 0;
    regs.flagC = val & 1 != 0;
    val = (val >> 1) | c;
    regs.setFlagsSZ(val);
    regs.flagH = false;
    regs.flagN = false;
    return val;
  }

  int rrc8(int val) {
    regs.flagC = val & 1 != 0;
    val = (val >> 1) | (val << 7);
    regs.setFlagsSZ(val);
    regs.flagH = false;
    regs.flagN = false;
    return val;
  }

  int sla8(int val) {
    regs.flagC = val & 0x80 != 0;
    val <<= 1;
    regs.setFlagsSZ(val);
    regs.flagH = false;
    regs.flagN = false;
    return val;
  }

  int sra8(int val) {
    regs.flagC = val & 1 != 0;
    val = (val & 0x80) | (val >> 1);
    regs.setFlagsSZ(val);
    regs.flagH = false;
    regs.flagN = false;
    return val;
  }

  int sll8(int val) {
    regs.flagC = val & 0x80 != 0;
    val = (val << 1) | 1;
    regs.setFlagsSZ(val);
    regs.flagH = false;
    regs.flagN = false;
    return val;
  }

  int srl8(int val) {
    regs.flagC = val & 1 != 0;
    val >>= 1;
    regs.setFlagsSZ(val);
    regs.flagH = false;
    regs.flagN = false;
    return val;
  }
}
