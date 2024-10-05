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
  List<int> mprAddress = List<int>.filled(8, 0);
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
      bus.read(regs.mprAddress[(addr & 0xe000) >> 13] | addr & 0x1fff);

  int readzp(int addr, {int cycle = 0}) {
    this.cycle += cycle;
    return bus.read(regs.mprAddress[1] | addr & 0xff);
  }

  int readsp(int addr) => bus.read(regs.mprAddress[1] | 0x100 | addr & 0xff);

  void write(int addr, int data) {
    // if (data >= 256) {
    //   print("cpu.write: data over 8bit: $data, regs: ${hex16(regs.pc)}\n");
    // }
    bus.write(regs.mprAddress[(addr & 0xe000) >> 13] | addr & 0x1fff, data);
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
    regs.mprAddress[7] = 0;

    const addr = 0xfffe;
    regs.pc = read(addr) | read(addr + 1) << 8;
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
    return readsp(regs.s);
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

  int readAddressing(int op, {bool st = false}) => switch (op) {
        0xa0 || 0xa2 || 0xc0 || 0xe0 => immediate(),
        _ => switch (op & 0x1c) {
            0x08 => immediate(),
            0x04 => readzp(pc(), cycle: 1),
            0x14 => readzp(pc() + regs.x, cycle: 2),
            _ => read(address(op, st: st))
          }
      };

  int address(int op, {bool st = false}) => switch (op & 0x1c) {
        0x04 => zeropage(), // 001
        0x14 => zeropageXY(regs.x), // 101
        0x0c => absolute(), // 011
        0x1c => absoluteXY(regs.x, st: st), // 111
        0x18 => absoluteXY(regs.y, st: st), // 110
        0x00 => indirectX(), // 000
        0x10 => op & 0x0f == 0x02 ? indirect() : indirectY(st: st), // 010
        _ => 0, // log("unimplemented addressing mode: $op\n");
      };

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
    return pc() | pc() << 8;
  }

  int absoluteXY(int offset, {bool st = false}) {
    cycle += 2;
    final base = pc() | pc() << 8;
    return (base + offset) & 0xffff;
  }

  int indirect() {
    cycle += 4;
    final addr = pc();
    return readzp(addr) | readzp(addr + 1) << 8;
  }

  int indirectX() {
    cycle += 4;
    final addr = pc() + regs.x;
    return readzp(addr) | readzp(addr + 1) << 8;
  }

  int indirectY({bool st = false}) {
    cycle += 3;
    final addr = pc();
    final base = readzp(addr) | readzp(addr + 1) << 8;
    return (base + regs.y) & 0xffff;
  }
}
