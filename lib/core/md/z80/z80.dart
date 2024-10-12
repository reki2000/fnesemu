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

  int get bc => (r8[0] << 8) | r8[1];
  set bc(int val) {
    r8[0] = val >> 8;
    r8[1] = val & 0xff;
  }

  int get de => (r8[2] << 8) | r8[3];
  set de(int val) {
    r8[2] = val >> 8;
    r8[3] = val & 0xff;
  }

  int get hl => (r8[4] << 8) | r8[5];
  set hl(int val) {
    r8[4] = val >> 8;
    r8[5] = val & 0xff;
  }

  int get ix => ixiy[0];
  set ix(int val) => ixiy[0] = val;

  int get iy => ixiy[1];
  set iy(int val) => ixiy[1] = val;

  static const S = 0x80;
  bool get sf => (f & S) != 0;
  set sf(bool on) => f = (on ? S : 0) | f & ~S;

  static const Z = 0x40;
  bool get zf => (f & Z) != 0;
  set zf(bool on) => f = (on ? Z : 0) | f & ~Z;

  static const H = 0x10;
  bool get hf => (f & H) != 0;
  set hf(bool on) => f = (on ? H : 0) | f & ~H;

  static const P = 0x04;
  static const V = 0x04;
  bool get pvf => (f & P) != 0;
  set pvf(bool on) => f = (on ? P : 0) | f & ~P;

  static const N = 0x02;
  bool get nf => (f & N) != 0;
  set nf(bool on) => f = (on ? N : 0) | f & ~N;

  static const C = 0x01;
  bool get cf => (f & C) != 0;
  set cf(bool on) => f = (on ? C : 0) | f & ~C;

  void setSZ(int result) {
    f = ((result == 0) ? Z : (result & 0x80)) | f & ~(Z | S);
  }

  void setV(int oldVal, int val, int newVal, {bool sub = false}) {
    pvf = sub
        ? (oldVal ^ val) & (oldVal ^ newVal) & 0x80 != 0
        : (oldVal ^ val ^ 0x80) & (val ^ newVal) & 0x80 != 0;
  }

  void setP(int result) {
    int count = result ^ (result >> 1);
    count = count ^ (count >> 2);
    count = count ^ (count >> 4);
    pvf = (count & 1) == 0;
  }
}

class Z80 {
  final BusZ80 bus;

  int clocks = 0;
  int cycles = 0;

  final r = Regs();

  bool iff1 = false;
  bool iff2 = false;
  int im = 0;

  bool halted = false;

  int repMode = repNone; // 1:ld 2:cp 3:in 4:out
  int repDirection = 1; // 1:inc -1:dec

  static const repNone = 0;
  static const repLd = 1;
  static const repCp = 2;
  static const repIn = 3;
  static const repOut = 4;

  Z80(this.bus);

  bool exec() {
    // interrupt

    // halt

    final op = next();

    if (op < 0x40) {
      return exec003f(op);
    }

    if (op < 0xc0) {
      return exec40bf(op);
    }

    return switch (op) {
      0xfd => execDdFd(next(), 1),
      0xdd => execDdFd(next(), 0),
      0xed => execEd(next()),
      0xcb => execCb(next()),
      _ => execC0ff(op)
    };
  }

  int read(int addr) => bus.read(addr);
  void write(int addr, int data) => bus.write(addr, data);

  int input(int port) => bus.input(port);
  void output(int port, int data) => bus.output(port, data);

  int next() {
    final d = read(r.pc);
    cycles += 4;
    r.pc = (r.pc + 1) & 0xffff;
    r.r = (r.r + 1) & 0x7f | r.r & 0x80;
    return d;
  }

  int pc8() {
    final d = read(r.pc);
    cycles += 3;
    r.pc = (r.pc + 1) & 0xffff;
    return d;
  }

  int pc16() {
    final d0 = read(r.pc);
    final d1 = read(r.pc + 1);
    cycles += 6;
    r.pc = (r.pc + 2) & 0xffff;
    return d0 | d1 << 8;
  }

  int rel8() {
    final d = pc8();
    return (d & 0x80) != 0 ? d - 0x100 : d;
  }

  int pop() {
    final d = read(r.sp).withHighByte(read((r.sp + 1) & 0xffff));
    cycles += 6;
    r.sp = (r.sp + 2) & 0xffff;
    return d;
  }

  void push(int d) {
    r.sp = (r.sp - 2) & 0xffff;
    write(r.sp, d & 0xff);
    write((r.sp + 1) & 0xffff, d >> 8);
    cycles += 7;
  }

  int readReg(int reg) {
    if (reg == 6) {
      cycles += 3;
      return read(r.hl);
    } else {
      return r.r8[reg];
    }
  }

  int readRegXY(int reg, int xy, int rel) {
    if (reg == 6) {
      cycles += 3;
      return read(r.ixiy[xy] + rel);
    } else if (reg == 4) {
      return r.ixiy[xy] >> 8;
    } else if (reg == 5) {
      return r.ixiy[xy] & 0xff;
    } else {
      return r.r8[reg];
    }
  }

  void writeReg(int reg, int data) {
    if (reg == 6) {
      write(r.hl, data);
      cycles += 3;
    } else {
      r.r8[reg] = data;
    }
  }

  void writeRegXY(int reg, int xy, int rel, int data) {
    if (reg == 6) {
      write(r.ixiy[xy] + rel, data);
      cycles += 3;
    } else if (reg == 4) {
      r.ixiy[xy] = r.ixiy[xy].withHighByte(data);
    } else if (reg == 5) {
      r.ixiy[xy] = r.ixiy[xy].withLowByte(data);
    } else {
      r.r8[reg] = data;
    }
  }

  int add16(int org, int val, {int c = 0}) {
    final result = org + val + c;
    r.hf = (org & 0xfff) + (val & 0xfff) > 0xfff;
    r.cf = result > 0xffff;
    r.nf = false;
    cycles += 7;
    return result & 0xffff;
  }

  int sbc16(int org, int val) {
    final result = org - val - (r.cf ? 1 : 0);
    r.hf = (org & 0xfff) - (val & 0xfff) - (r.cf ? 1 : 0) < 0;
    r.cf = result < 0;
    r.nf = true;
    cycles += 7;
    return result & 0xffff;
  }

  int inc8(int val) {
    final result = (val + 1) & 0xff;
    r.setSZ(result);
    r.pvf = val == 0x7f;
    r.hf = (val & 0x0f) == 0x0f;
    r.nf = false;
    return result;
  }

  int dec8(int val) {
    final result = (val - 1) & 0xff;
    r.setSZ(result);
    r.pvf = val == 0x80;
    r.hf = (val & 0x0f) == 0x00;
    r.nf = true;
    return result & 0xff;
  }

  void add8(int val, int c) {
    final result = r.a + val + c;
    r.setSZ(result);
    r.setV(r.a, val, result);
    r.hf = (r.a & 0xf) + (val & 0xf) > 0xf;
    r.nf = false;
    r.cf = result > 0xff;
    r.a = result & 0xff;
  }

  void sub8(int val, int c) {
    final result = r.a - val - c;
    r.setSZ(result);
    r.setV(r.a, val + c, result, sub: true);
    r.hf = (r.a & 0xf) < (val & 0xf);
    r.nf = true;
    r.cf = result < 0;
    r.a = result & 0xff;
  }

  void and8(int val) {
    r.a &= val;
    r.setSZ(r.a);
    r.setP(r.a);
    r.hf = true;
    r.nf = false;
    r.cf = false;
  }

  void or8(int val) {
    r.a |= val;
    r.setSZ(r.a);
    r.setP(r.a);
    r.hf = false;
    r.nf = false;
    r.cf = false;
  }

  void xor8(int val) {
    r.a ^= val;
    r.setSZ(r.a);
    r.setP(r.a);
    r.hf = false;
    r.nf = false;
    r.cf = false;
  }

  void cp8(int val) {
    final result = r.a - val;
    r.setSZ(result);
    r.setV(r.a, val, result, sub: true);
    r.hf = (r.a & 0xf) - (val & 0xf) < 0;
    r.nf = true;
    r.cf = result < 0;
  }

  int rl8(int val, {bool setSZP = true}) {
    final c = r.cf ? 1 : 0;
    r.cf = val & 0x80 != 0;
    val = ((val << 1) | c) & 0xff;
    r.hf = false;
    r.nf = false;
    if (!setSZP) return val;
    r.setSZ(val);
    r.setP(val);
    return val;
  }

  int rlc8(int val, {bool setSZP = true}) {
    r.cf = val & 0x80 != 0;
    val = ((val << 1) | (val >> 7)) & 0xff;
    r.hf = false;
    r.nf = false;
    if (!setSZP) return val;
    r.setSZ(val);
    r.setP(val);
    return val;
  }

  int rr8(int val, {bool setSZP = true}) {
    final c = r.cf ? 0x80 : 0;
    r.cf = val & 1 != 0;
    val = (val >> 1) | c;
    r.hf = false;
    r.nf = false;
    if (!setSZP) return val;
    r.setSZ(val);
    r.setP(val);
    return val;
  }

  int rrc8(int val, {bool setSZP = true}) {
    r.cf = val & 1 != 0;
    val = (val >> 1) | ((val & 1) << 7);
    r.hf = false;
    r.nf = false;
    if (!setSZP) return val;
    r.setSZ(val);
    r.setP(val);
    return val;
  }

  int sla8(int val) {
    r.cf = val & 0x80 != 0;
    val = (val << 1) & 0xff;
    r.setSZ(val);
    r.setP(val);
    r.hf = false;
    r.nf = false;
    return val & 0xff;
  }

  int sra8(int val) {
    r.cf = val & 1 != 0;
    val = (val & 0x80) | (val >> 1);
    r.setSZ(val);
    r.setP(val);
    r.hf = false;
    r.nf = false;
    return val;
  }

  int sll8(int val) {
    r.cf = val & 0x80 != 0;
    val = ((val << 1) | 1) & 0xff;
    r.setSZ(val);
    r.setP(val);
    r.hf = false;
    r.nf = false;
    return val;
  }

  int srl8(int val) {
    r.cf = val & 1 != 0;
    val >>= 1;
    r.setSZ(val);
    r.setP(val);
    r.hf = false;
    r.nf = false;
    return val;
  }
}
