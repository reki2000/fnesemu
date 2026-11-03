import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

import '../../../components/r3000/bus.dart';
import '../../../components/r3000/coprocessor.dart';
import '../../../components/r3000/r3000.dart';
import '../../../util/debug.dart';
import '../../../util/int.dart';
import '../../../util/uint8list.dart';
import '../log.dart';
import '../state.dart';

part 'bios.dart';
part 'cop2.dart';
part 'cop2_command.dart';
part 'cop2_math.dart';
part 'hook.dart';

final _log = DebugLog('ps.r3000');

/// The bus interface of the PS CPU, the shared R3000 bus under its established name.
typedef BusR3000 = R3000Bus;

typedef RegNo = int;

/// The PS embedding of the shared R3000 core: the GTE on COP2, the COP0 registers as individual fields over the shared COP0 storage, the BIOS call hooks and the two-clocks-per-instruction step cycle.
class R3000 extends R3000Core {
  JitExecutionStats? executionStats;

  @override
  late final Cop2 cop2;

  /// [regs] places the registers in memory shared with a recompiler
  R3000(super.bus, {super.regs}) {
    cop2 = Cop2(this);
  }

  /// The COP0 status register.
  int get sr => cop0[R3000Core.cop0Status];
  set sr(int value) => cop0[R3000Core.cop0Status] = value;

  /// The COP0 cause register.
  int get cause => cop0[R3000Core.cop0Cause];
  set cause(int value) => cop0[R3000Core.cop0Cause] = value;

  /// The COP0 exception program counter.
  int get epc => cop0[R3000Core.cop0Epc];
  set epc(int value) => cop0[R3000Core.cop0Epc] = value;

  /// The COP0 bad virtual address register.
  int get badvaddr => cop0[R3000Core.cop0BadVAddr];
  set badvaddr(int value) => cop0[R3000Core.cop0BadVAddr] = value;

  /// The COP0 target register.
  int get tar => cop0[6];
  set tar(int value) => cop0[6] = value;

  // bios putchar() hacking
  final console = StringBuffer();

  /// called with each line that the program writes to the tty (bios putchar
  /// and write to stdout / stderr), without the line feed
  void Function(String line)? onTtyLine;

  // ps-exe bianry to be sideloaded
  Uint8List exe = Uint8List(0);

  @override
  bool linksRegimm(int rt) => rt == 0x10 || rt == 0x11;

  @override
  bool cop0CommandApplies(int rs) => rs >= 0x10;

  @override
  void recordMemory(int addr, int size, {bool write = false, bool fetch = false}) =>
      executionStats?.recordMemory(addr, size, write: write, fetch: fetch);

  @override
  int readCop0(int reg) {
    return switch (reg) {
      6 => tar,
      8 => badvaddr,
      12 => sr,
      13 => cause,
      14 => epc,
      15 => 0x00000002,
      _ => 0,
    };
  }

  @override
  void writeCop0(int reg, int value) {
    switch (reg) {
      case 6:
        tar = value;
      case 8:
        badvaddr = value;
      case 12:
        // _log.debugc(() => "sr <- ${value.x8}");
        sr = value;
      case 13:
        cause = cause.masked(0x300, value);
      case 14:
        epc = value;
    }
  }

  @override
  void exception(int excode, {int coprocessor = 0, int? badvaddr}) {
    sr = sr.masked(0x3f,
        sr.shl2); // save old mode, ie bit0-1, and set new mode to kernel (0x00)

    cause &= 0xff00; // clear, keep bit8-15 (IM)
    cause |= excode.shl2;

    if (badvaddr != null) {
      this.badvaddr = badvaddr;
    }

    if (inDelaySlot) {
      epc = instPc.dec4.mask32;
      cause |= 0x80000000.setBit(30, delaySlotTaken);
      tar = pc;
    } else {
      epc = instPc;
    }

    pc = sr.bit22 ? 0xbfc00180 : 0x80000080; // bit22: BEV
    nextPc = pc.inc4;

    // _log.debugc(() =>
    //     "exception  excode:${excode.x2} sr:${sr.x8} cause:${cause.x8} epc:${epc.x8}");
  }

  void reset() {
    pc = 0xbfc00000;
    nextPc = pc.inc4;

    nextDelayReg = 0;
    nextDelayVal = 0;
    immediateReg = 0;
    immediateVal = 0;

    inBranchTaken = false;
    inBranchDelay = false;
    inDelaySlot = false;
    delaySlotTaken = false;

    r.fillRange(0, 32, 0);
    hi = 0;
    lo = 0;

    sr = 0;
    cause = 0;
    epc = 0;
    tar = 0;

    clocks = 0;

    console.clear();

    cop2.reset();
  }

  void saveState(StateWriter w) {
    w.section('ps-cpu');
    w.typed(r);
    w.typed(cop0);
    w.ints([
      pc, nextPc, instPc, hi, lo, clocks, nextDelayReg, nextDelayVal, //
      delayReg, delayVal, immediateReg, immediateVal,
    ]);
    for (final b in [inBranchTaken, inBranchDelay, inDelaySlot, delaySlotTaken]) {
      w.boolean(b);
    }
    w.string(console.toString());
    cop2.saveState(w);
  }

  void loadState(StateReader s) {
    s.section('ps-cpu');
    s.typed(r);
    s.typed(cop0);
    final v = s.fields(12, 'ps cpu');
    pc = v[0];
    nextPc = v[1];
    instPc = v[2];
    hi = v[3];
    lo = v[4];
    clocks = v[5];
    nextDelayReg = v[6];
    nextDelayVal = v[7];
    delayReg = v[8];
    delayVal = v[9];
    immediateReg = v[10];
    immediateVal = v[11];
    inBranchTaken = s.boolean();
    inBranchDelay = s.boolean();
    inDelaySlot = s.boolean();
    delaySlotTaken = s.boolean();
    console
      ..clear()
      ..write(s.string());
    cop2.loadState(s);
  }

  void setInterruptPending(bool onoff) =>
      cause = cause.setBit(10, onoff); // set cop0.cuase.ip2 on

  /// Executes a single instruction.
  /// Register indices below are masked to five bits before accessing the
  /// fixed 32-entry register file; keep that invariant with bounds checks off.
  @pragma('vm:unsafe:no-bounds-checks')
  bool step() {
    final stats = executionStats;
    if (stats == null) return _step();
    final at = pc, before = clocks;
    final opcode = stats.opcodeAt(at);
    stats.beginCpuStep();
    try {
      return _step();
    } finally {
      stats.endCpuStep();
      stats.recordCpuStep(at, opcode, clocks - before);
    }
  }

  @pragma('vm:unsafe:no-bounds-checks')
  bool _step() {
    hook();

    instPc = pc; // points the current instruction.
    pc = nextPc; // points the next instruction. "PC" refers this.
    nextPc = nextPc.inc4.mask32;

    delayReg = nextDelayReg;
    delayVal = nextDelayVal;
    nextDelayReg = 0;
    nextDelayVal = 0;
    immediateReg = 0;
    immediateVal = 0;

    inDelaySlot = inBranchDelay;
    delaySlotTaken = inBranchTaken;
    inBranchTaken = false;
    inBranchDelay = false;

    if ((cause & sr & 0xff00 != 0) &&
        sr.bit0 &&
        read32(instPc, instruction: true).shr26 != 0x12) {
      // delay excaption if the current instruction is cop2
      exception(R3000Core.excInterrupt);
    } else {
      exec(read32(instPc, instruction: true));
    }

    r[delayReg.mask5] = delayVal;
    r[immediateReg.mask5] = immediateVal;

    r[0] = 0; // r0 is always hardwired to 0.

    clocks += 2; // not accurate, but enough for now.

    return true;
  }

  String dump() {
    final regs = [
      for (int i = 0; i < 32; i += 8)
        "r${i.d2z}:"
            "${range(i, i + 4).map((v) => r[v].x8).join(" ")}"
            " r${(i + 4).d2z}:"
            "${range(i + 4, i + 8).map((v) => r[v].x8).join(" ")}"
    ].join("\n");
    return "$regs\npc:${pc.x8} hi:${hi.x8} lo:${lo.x8} sr:${sr.x8} cause:${cause.x8} epc:${epc.x8}";
  }
}
