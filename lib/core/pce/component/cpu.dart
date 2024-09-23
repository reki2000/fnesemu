// Dart imports:
import 'dart:core';
import 'dart:developer';

import '../../../util.dart';
import 'bus.dart';
import 'cpu_6280.dart';
import 'cpu_6502.dart';
import 'cpu_65c02.dart';

class Regs {
  int a = 0;
  int x = 0;
  int y = 0;
  int s = 0;
  int p = 0;
  int pc = 0;
  List<int> mpr = List<int>.filled(8, 0);
}

class Flags {
  static const C = 0x01;
  static const Z = 0x02;
  static const I = 0x04;
  static const D = 0x08;
  static const B = 0x10;
  static const T = 0x20;
  static const V = 0x40;
  static const N = 0x80;
}

class Cpu2 extends Cpu {
  Cpu2(super.bus) {
    bus.cpu = this;
  }

  bool exec() {
    cycle = 0;

    final op = pc();
    final result = exec6502(op) || exec65c02(op) || exec6280(op);

    if (!result) {
      log("unimplemented opcode: ${hex8(op)} at ${hex16(regs.pc)}\n");
      cycle += 2;
    }

    clock = cycle *
        (isHighSpeed ? Cpu.highSpeedClockPerCycle : Cpu.lowSpeedClockPerCycle);

    cycles += cycle;
    clocks += clock;

    handleIrq();

    return result;
  }
}

enum Interrupt {
  irq1,
  irq2,
  tirq,
  nmi,
}

class Cpu {
  final Bus bus;

  Cpu(this.bus);

  final regs = Regs();

  bool isHighSpeed = false;
  static const highSpeedClockPerCycle = 3;
  static const lowSpeedClockPerCycle = 12;

  int cycle = 0;
  int clock = 0;

  int cycles = 0;
  int clocks = 0;

  static const zeroAddr = 0x2000;
  static const stackAddr = 0x2100;

  bool tFlagOn = false;

  int read(int addr) =>
      bus.read((regs.mpr[(addr & 0xe000) >> 13] << 13) | addr & 0x1fff);

  void write(addr, data) {
    // if (data >= 256) {
    //   print("cpu.write: data over 8bit: $data, regs: ${hex16(regs.pc)}\n");
    // }
    bus.write(((regs.mpr[(addr & 0xe000) >> 13] << 13) | addr & 0x1fff), data);
  }

  void handleIrq() {
    // exec irq on the next execution
    if (holdIrq1 && (regs.p & Flags.I) == 0) {
      holdIrq1 = false;
      interrupt(irq1: true);
    }

    // exec irq on the next execution
    if (holdIrq2 && (regs.p & Flags.I) == 0) {
      holdIrq2 = false;
      interrupt(irq2: true);
    }

    // exec irq on the next execution
    if (holdTirq && (regs.p & Flags.I) == 0) {
      holdTirq = false;
      interrupt(tirq: true);
    }

    // exec nmi on the next execution
    if (holdNmi) {
      holdNmi = false;
      interrupt(nmi: true);
    }

    if (tFlagOn) {
      regs.p |= Flags.T;
      tFlagOn = false;
    } else {
      regs.p &= ~Flags.T;
    }
  }

  // interrupt handling
  void holdInterrupt(Interrupt int) {
    // print("interrupted: $int ${hex16(regs.pc)}");
    switch (int) {
      case Interrupt.irq1:
        holdIrq1 = true;
        break;
      case Interrupt.irq2:
        holdIrq2 = true;
        break;
      case Interrupt.tirq:
        holdTirq = true;
        break;
      case Interrupt.nmi:
        holdNmi = true;
        break;
    }
  }

  void releaseInterrupt(Interrupt int) {
    switch (int) {
      case Interrupt.irq1:
        holdIrq1 = false;
        break;
      case Interrupt.irq2:
        holdIrq2 = false;
        break;
      case Interrupt.tirq:
        holdTirq = false;
        break;
      case Interrupt.nmi:
        holdNmi = false;
        break;
    }
  }

  bool holdNmi = false;
  bool holdIrq1 = false;
  bool holdIrq2 = false;
  bool holdTirq = false;

  void interrupt(
      {bool brk = false,
      bool nmi = false,
      bool irq1 = false,
      bool irq2 = false,
      bool tirq = false}) {
    final pushAddr = brk ? regs.pc + 1 : regs.pc;
    push(pushAddr >> 8);
    push(pushAddr & 0xff);
    push(regs.p);
    regs.p = (regs.p & ~Flags.B) | (brk ? Flags.B : 0) | Flags.I;

    final addr = irq2
        ? 0xfff6
        : irq1
            ? 0xfff8
            : tirq
                ? 0xfffa
                : nmi
                    ? 0xfffc
                    : 0xfffe;
    regs.pc = read(addr) | (read(addr + 1) << 8);
  }

  void reset() {
    cycles = 0;
    clocks = 0;

    holdIrq1 = false;
    holdIrq2 = false;
    holdTirq = false;
    holdNmi = false;

    tFlagOn = false;

    isHighSpeed = false;
    cycle = 0;
    clock = 0;
    cycles = 0;
    clocks = 0;

    regs.a = 0;
    regs.x = 0;
    regs.y = 0;

    regs.s = 0xfd;
    regs.p = 0x00 | Flags.B;

    regs.mpr[7] = 0;

    const addr = 0xfffe;
    regs.pc = read(addr) | (read(addr + 1) << 8);
  }

  // common operations

  void push(int val) {
    write(regs.s | stackAddr, val);
    regs.s--;
    regs.s &= 0xff;
  }

  int pop() {
    regs.s++;
    regs.s &= 0xff;
    return read(regs.s | stackAddr);
  }

  int pc() {
    final op = read(regs.pc);
    regs.pc = (regs.pc + 1) & 0xffff;
    return op;
  }

  void branch(bool cond) {
    final offset = ((immediate() + 128) & 0xff) - 128;
    if (cond) {
      regs.pc = (regs.pc + offset) & 0xffff;
    }
    cycle += 2;
  }

  void flagsV(int a, int b, int acm, {bool sub = false}) {
    flags(acm, sub: sub);
    final overflow = (((a ^ acm) & ((sub ? ~b : b) ^ acm)) & 0x80) >> 1;
    regs.p = (regs.p & ~Flags.V) | overflow;
  }

  void flags(int acm, {bool sub = false}) {
    var carry = (acm & 0x100 != 0) ? Flags.C : 0;
    if (sub) {
      carry ^= Flags.C;
    }
    regs.p = (regs.p & ~Flags.C) | carry;
    flagsNZ(acm);
  }

  void flagsNZ(int acm) {
    final negative = bit7(acm) ? Flags.N : 0;
    final zero = (acm & 0xff == 0) ? Flags.Z : 0;

    regs.p = (regs.p & 0x7d) | Flags.T | negative | zero;
  }

  int carry() {
    return regs.p & Flags.C;
  }

  bool isDecimal() {
    return regs.p & Flags.D != 0;
  }

  int readAddressing(int op, {bool st = false}) {
    return ((op & 0x1c == 0x08) ||
            op == 0xa0 ||
            op == 0xa2 ||
            op == 0xc0 ||
            op == 0xe0)
        ? immediate()
        : read(address(op, st: st));
  }

  int address(int op, {bool st = false}) {
    switch (op & 0x1c) {
      case 0x04: // 001
        return zeropage();
      case 0x14: // 101
        return zeropageXY(regs.x);
      case 0x0c: // 011
        return absolute();
      case 0x1c: // 111
        return absoluteXY(regs.x, st: st);
      case 0x18: // 110
        return absoluteXY(regs.y, st: st);
      case 0x00: // 000
        return indirectX();
      case 0x10: // 100
        return op & 0x0f == 0x02 ? indirect() : indirectY(st: st);
      default:
        log("umimplemented addressing mode: $op\n");
        return 0;
    }
  }

  int immediate() => pc();

  int zeropage() {
    cycle += 1;
    return pc() | zeroAddr;
  }

  int zeropageXY(int offset) {
    cycle += 2;
    return (pc() + offset) & 0xff | zeroAddr;
  }

  int absolute() {
    cycle += 2;
    return (pc() | (pc() << 8));
  }

  int absoluteXY(int offset, {bool st = false}) {
    final base = (pc() | (pc() << 8));
    if (st || (base & 0xff00 != (base + offset) & 0xff00)) {
      cycle += 3;
    } else {
      cycle += 2;
    }
    return (base + offset) & 0xffff;
  }

  int indirect() {
    cycle += 4;
    final addr = pc();
    return read(addr | zeroAddr) | (read((addr + 1) & 0xff | zeroAddr) << 8);
  }

  int indirectX() {
    cycle += 4;
    final addr = (pc() + regs.x) & 0xff;
    return read(addr | zeroAddr) | (read((addr + 1) & 0xff | zeroAddr) << 8);
  }

  int indirectY({bool st = false}) {
    final addr = pc();
    final base =
        (read(addr | zeroAddr) | (read((addr + 1) & 0xff | zeroAddr) << 8));
    if (st || (base & 0xff00 != (base + regs.y) & 0xff00)) {
      cycle += 4;
    } else {
      cycle += 3;
    }
    return (base + regs.y) & 0xffff;
  }
}
