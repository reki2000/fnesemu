import 'package:fnesemu/core/md/z80/op_40_bf.dart';
import 'package:fnesemu/core/md/z80/op_c0_ff.dart';
import 'package:fnesemu/core/md/z80/op_cb.dart';
import 'package:fnesemu/core/md/z80/op_ddfd.dart';
import 'package:fnesemu/core/md/z80/op_ed.dart';
import 'package:fnesemu/util/int.dart';

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

  int get clocks => cycles;
  int cycles = 0;

  final r = Regs();

  bool iff1 = false;
  bool iff2 = false;
  int im = imRst38;
  static const im8080 = 0;
  static const imRst38 = 1;
  static const imVector = 2;

  bool _intAsserted = false;

  bool halted = false;

  Z80(this.bus);

  void interrupt() {
    _intAsserted = true;
  }

  bool exec() {
    // interrupt
    if (_intAsserted && iff1) {
      _intAsserted = false;
      push(r.pc);
      r.pc = 0x38;
      cycles += 13;
      return true;
    }

    // halt
    if (halted) {
      cycles += 4;
      return true;
    }

    // print(dump().replaceAll("\n", " "));
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
    r.pc = r.pc.inc.mask16;
    r.r = r.r.inc & 0x7f | r.r & 0x80;
    return d;
  }

  int pc8() {
    final d = read(r.pc);
    cycles += 3;
    r.pc = r.pc.inc.mask16;
    return d;
  }

  int pc16() {
    final d0 = read(r.pc);
    final d1 = read(r.pc.inc.mask16);
    cycles += 6;
    r.pc = r.pc.inc2.mask16;
    return d0 | d1 << 8;
  }

  int rel8() {
    final d = pc8();
    return d.bit7 ? d - 0x100 : d;
  }

  int pop() {
    final d = read(r.sp).setH8(read(r.sp.inc.mask16));
    cycles += 6;
    r.sp = r.sp.inc2.mask16;
    return d;
  }

  void push(int d) {
    r.sp = r.sp.dec2.mask16;
    write(r.sp, d & 0xff);
    write(r.sp.inc.mask16, d >> 8);
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
      r.ixiy[xy] = r.ixiy[xy].setH8(data);
    } else if (reg == 5) {
      r.ixiy[xy] = r.ixiy[xy].setL8(data);
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
    return result.mask16;
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
    r.nf = r.cf = false;
  }

  void or8(int val) {
    r.a |= val;
    r.setSZ(r.a);
    r.setP(r.a);
    r.hf = r.nf = r.cf = false;
  }

  void xor8(int val) {
    r.a ^= val;
    r.setSZ(r.a);
    r.setP(r.a);
    r.hf = r.nf = r.cf = false;
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
    r.hf = r.nf = false;
    if (!setSZP) return val;
    r.setSZ(val);
    r.setP(val);
    return val;
  }

  int rlc8(int val, {bool setSZP = true}) {
    r.cf = val & 0x80 != 0;
    val = ((val << 1) | (val >> 7)) & 0xff;
    r.hf = r.nf = false;
    if (!setSZP) return val;
    r.setSZ(val);
    r.setP(val);
    return val;
  }

  int rr8(int val, {bool setSZP = true}) {
    final c = r.cf ? 0x80 : 0;
    r.cf = val & 1 != 0;
    val = (val >> 1) | c;
    r.hf = r.nf = false;
    if (!setSZP) return val;
    r.setSZ(val);
    r.setP(val);
    return val;
  }

  int rrc8(int val, {bool setSZP = true}) {
    r.cf = val & 1 != 0;
    val = (val >> 1) | ((val & 1) << 7);
    r.hf = r.nf = false;
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
    r.hf = r.nf = false;
    return val & 0xff;
  }

  int sra8(int val) {
    r.cf = val & 1 != 0;
    val = (val & 0x80) | (val >> 1);
    r.setSZ(val);
    r.setP(val);
    r.hf = r.nf = false;
    return val;
  }

  int sll8(int val) {
    r.cf = val & 0x80 != 0;
    val = ((val << 1) | 1) & 0xff;
    r.setSZ(val);
    r.setP(val);
    r.hf = r.nf = false;
    return val;
  }

  int srl8(int val) {
    r.cf = val & 1 != 0;
    val >>= 1;
    r.setSZ(val);
    r.setP(val);
    r.hf = r.nf = false;
    return val;
  }

  void reset({bool keepCycles = false}) {
    r.pc = 0;
    r.sp = 0;
    r.i = 0;
    r.r = 0;
    iff1 = false;
    iff2 = false;
    im = 0;
    r.r8.fillRange(0, 8, 0);
    r.ixiy.fillRange(0, 2, 0);
    r.af2 = 0;
    r.bc2 = 0;
    r.de2 = 0;
    r.hl2 = 0;

    if (!keepCycles) {
      cycles = 0;
    }
  }

  String dump() {
    final res1 =
        "af:${(r.af & 0xffd7).hex16} bc:${r.bc.hex16} de:${r.de.hex16} hl:${r.hl.hex16}";
    final res2 =
        "af':${(r.af2 & 0xffd7).hex16} bc':${r.bc2.hex16} de':${r.de2.hex16} hl':${r.hl2.hex16}";
    final res3 =
        "ix:${r.ixiy[0].hex16} iy:${r.ixiy[1].hex16} sp:${r.sp.hex16} pc:${r.pc.hex16}";
    final regs4 =
        ("i:${r.i.hex8} r:${r.r.hex8} iff:${iff1 ? 1 : 0}${iff2 ? 1 : 0} im:$im ${halted ? "H" : "-"} cy:$cycles");

    const f = "SZ-H-PNC";
    final flags = List.generate(
        f.length,
        (i) => "$f${f.toLowerCase()}"[
            (r.f << i & (1 << f.length - 1)) != 0 ? i : f.length + i]).join();

    return "f:$flags $res1 $res2\n$res3 $regs4";
  }
}
