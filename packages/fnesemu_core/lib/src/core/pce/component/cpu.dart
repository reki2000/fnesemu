import 'dart:core';
import 'dart:typed_data';

import '../../../components/6502/cpu6502.dart';
import '../../../util/debug.dart';
import '../../../util/int.dart';
import '../../../util/state.dart';
import 'bus.dart';
import 'cpu_6280.dart';
import 'cpu_65c02.dart';

final _log = DebugLog('pce.cpu');

typedef Flags = Cpu6502Flags;

class Regs extends Cpu6502Regs {
  List<int> mpr = List<int>.filled(8, 0);
  final mprAddress = Int32List(8); // mpr << 13
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
      _log.warnc(() => "unimplemented opcode: ${op.x2} at ${regs.pc.x4}\n");
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

/// The Hudson HuC6280 variant layer over the shared 6502 engine. This layer
/// enables the engine's decimal mode and T flag hooks, drops the page cross
/// penalties, and wires the engine to the PCE bus through the MPR memory
/// paging: every engine access is a logical address that this layer
/// translates, and the zero page and stack bases place them in the paged
/// work ram page. The 65C02 additions live in cpu_65c02.dart and the
/// HuC6280 only instructions, including the block transfers that run through
/// this paging, live in cpu_6280.dart.
class Cpu extends Cpu6502<Regs> {
  final Bus bus;

  Cpu(this.bus) : super(Regs());

  @override
  bool get decimalEnabled => true;

  @override
  bool get supportsTFlag => true;

  @override
  bool get pageCrossPenalty => false;

  @override
  bool get zeroPageIndirect => true;

  @override
  int get zeroPageBase => Cpu.zeroAddr;

  @override
  int get stackBase => Cpu.stackAddr;

  bool isHighSpeed = false;
  static const highSpeedClockPerCycle = 3;
  static const lowSpeedClockPerCycle = 12;

  int clock = 0;

  int cycles = 0;
  int clocks = 0;

  static const zeroAddr = 0x2000;
  static const stackAddr = 0x2100;

  bool tFlagOn = false;

  @override
  @pragma('vm:prefer-inline')
  int read(int addr) =>
      bus.read(regs.mprAddress[addr.shr13.mask3] | addr.mask13);

  int readzp(int addr, {int cycle = 0}) => readZeroPage(addr, cycle: cycle);

  int readsp(int addr) => bus.read(regs.mprAddress[1] | 0x100 | addr.mask8);

  @override
  void write(int addr, int data) {
    bus.write(regs.mprAddress[(addr & 0xe000).shr13] | addr.mask13, data);
  }

  @override
  int statusForPhp() => (regs.p | Flags.B) & ~Flags.T;

  // the interrupt mask register is written in the last cycle of the store
  // instruction, so an interrupt unmasked by it is entered only after the next
  // instruction (handlers unmask and acknowledge the timer irq back to back)
  bool _irqInhibitOnce = false;

  void inhibitIrqOnce() => _irqInhibitOnce = true;

  void handleIrq() {
    final inhibit = _irqInhibitOnce;
    _irqInhibitOnce = false;

    if (holdIrq1 || holdIrq2 || holdTirq || holdNmi) {
      _enterInterrupts(inhibit);
    }

    if (tFlagOn) {
      regs.p |= Flags.T;
      tFlagOn = false;
    } else {
      regs.p &= ~Flags.T;
    }
  }

  void _enterInterrupts(bool inhibit) {
    // exec irq on the next execution
    if (!inhibit && holdIrq1 && (regs.p & Flags.I) == 0) {
      holdIrq1 = false;
      interrupt(irq1: true);
    }

    // exec irq on the next execution
    if (!inhibit && holdIrq2 && (regs.p & Flags.I) == 0) {
      holdIrq2 = false;
      interrupt(irq2: true);
    }

    // exec irq on the next execution
    if (!inhibit && holdTirq && (regs.p & Flags.I) == 0) {
      holdTirq = false;
      interrupt(tirq: true);
    }

    // exec nmi on the next execution
    if (holdNmi) {
      holdNmi = false;
      interrupt(nmi: true);
    }
  }

  // interrupt handling
  void holdInterrupt(Interrupt int) {
    // _log.debugc(() => "interrupted: $int ${regs.pc.x4}");
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

  /// Saves the shared 6502 state, the MPR paging registers and this layer's speed, clock and interrupt state; the MPR address cache is derived from the MPR values and is rebuilt on load.
  @override
  void saveState(StateWriter w) {
    super.saveState(w);
    w.section('pce-cpu');
    w.ints(regs.mpr);
    w.ints([clock, cycles, clocks]);
    w.boolean(isHighSpeed);
    w.boolean(tFlagOn);
    w.boolean(_irqInhibitOnce);
    w.boolean(holdNmi);
    w.boolean(holdIrq1);
    w.boolean(holdIrq2);
    w.boolean(holdTirq);
  }

  /// Restores the state written by [saveState].
  @override
  void loadState(StateReader s) {
    super.loadState(s);
    s.section('pce-cpu');
    s.intsInto(regs.mpr);
    for (var i = 0; i < 8; i++) {
      regs.mprAddress[i] = regs.mpr[i].shl13;
    }
    final v = s.ints();
    if (v.length != 3) throw const StateMismatch('pce cpu state layout');
    clock = v[0];
    cycles = v[1];
    clocks = v[2];
    isHighSpeed = s.boolean();
    tFlagOn = s.boolean();
    _irqInhibitOnce = s.boolean();
    holdNmi = s.boolean();
    holdIrq1 = s.boolean();
    holdIrq2 = s.boolean();
    holdTirq = s.boolean();
  }

  @override
  void interrupt(
      {bool brk = false,
      bool nmi = false,
      bool irq1 = false,
      bool irq2 = false,
      bool tirq = false}) {
    final pushAddr = brk ? regs.pc + 1 : regs.pc;
    push(pushAddr.shr8);
    push(pushAddr.mask8);
    // the B flag is set in the pushed flags only by BRK. regs.p still holds
    // the T flag of the instruction that has just run; only a SET just before
    // leaves T set for the instruction to return to.
    push(brk
        ? (regs.p | Flags.B) & ~Flags.T
        : (regs.p & ~(Flags.B | Flags.T)) | (tFlagOn ? Flags.T : 0));
    // the handler starts in binary mode, and a SET just before does not
    // apply to its first instruction
    regs.p = (regs.p & ~(Flags.D | Flags.T)) | Flags.I;
    tFlagOn = false;

    // BRK shares the vector of IRQ2
    final addr = irq2 || brk
        ? 0xfff6
        : irq1
            ? 0xfff8
            : tirq
                ? 0xfffa
                : nmi
                    ? 0xfffc
                    : 0xfffe;
    regs.pc = read(addr) | read(addr + 1).shl8;
  }

  /// PLP and RTI: the B flag is not kept, and a pulled T flag stays set for the next instruction.
  @override
  void pullFlags(int p) {
    regs.p = p & ~Flags.B;
    tFlagOn = p & Flags.T != 0;
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
    regs.pc = read(addr) | read(addr + 1).shl8;
  }

}
