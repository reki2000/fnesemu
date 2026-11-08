import 'dart:typed_data';

import '../../../components/arm7/arm7.dart';
import '../../../components/arm7/regs.dart';
import '../../../util/int.dart';
import '../../../util/state.dart';
import '../bus.dart';

/// ARM7TDMI core: the GBA embedding of the shared ARM7 engine.
///
/// The engine executes the ARM and Thumb instruction sets; this class
/// adds what is GBA-specific: the bus interface, the step cycle, the
/// exception entries the bus and the decoders raise, the BIOS-less boot
/// sequence, and the CPU save-state format. Cycle costs are the flat
/// per-instruction table the TDMI core has always charged.
class Arm7 extends Arm7Core {
  final Bus bus;

  /// [registers] optionally supplies the register store, so a JIT
  /// context can share it with the interpreter (see GbaJit).
  Arm7(this.bus, {Uint32List? registers})
      : super(registers: registers, hasThumb: true, armV4: true);

  int cycles = 0;

  /// The address of the instruction that executes next: the fetch
  /// pointer two instructions back, in the current state.
  int get pc => regs.r[15] - _opSize * 2;

  // Exception vector addresses.
  static const _vectorUndefined = 0x04;
  static const _vectorSwi = 0x08;
  static const _vectorAbortPrefetch = 0x0c;
  static const _vectorAbortData = 0x10;
  static const _vectorIrq = 0x18;
  static const _vectorFiq = 0x1c;

  @override
  int fetch(int address) =>
      regs.thumb ? bus.fetch16(address & ~1) : bus.fetch32(address & ~3);

  @override
  int readMem(int address, int size) => switch (size) {
        1 => bus.read8(address),
        2 => bus.read16(address),
        _ => bus.read32(address),
      };

  @override
  void writeMem(int address, int size, int value) {
    switch (size) {
      case 1:
        bus.write8(address, value);
      case 2:
        bus.write16(address, value);
      default:
        bus.write32(address, value);
    }
  }

  @override
  int msrMask(int op, bool toSpsr) {
    // Field mask bits: 16 control, 17 extension, 18 status, 19 flags.
    var mask = 0;
    if (op.bit16) mask |= 0x000000ff;
    if (op.bit17) mask |= 0x0000ff00;
    if (op.bit18) mask |= 0x00ff0000;
    if (op.bit19) mask |= 0xff000000;
    // In user mode only the flag byte of the CPSR is writable.
    if (!toSpsr && regs.mode == CpuMode.usr) mask &= 0xff000000;
    return mask;
  }

  @override
  void onSwi() => raiseSwi();

  @override
  void onUndefined() => raiseUndefined();

  void reset() {
    regs.reset();
    regs.r[15] = 8; // fetch pointer for the BIOS entry at 0
  }

  /// Reset without a real BIOS: emulate the boot sequence the BIOS
  /// performs (set up the SVC/IRQ/SYS stack pointers and jump to the
  /// cartridge entry). Lets polling-based ROMs run without a
  /// copyrighted BIOS image.
  void resetHle() {
    regs.reset();
    regs.switchMode(CpuMode.irq);
    regs.r[13] = 0x03007fa0;
    regs.switchMode(CpuMode.svc);
    regs.r[13] = 0x03007fe0;
    regs.switchMode(CpuMode.sys);
    regs.r[13] = 0x03007f00;
    regs.cpsr = CpuMode.sys; // IRQ/FIQ enabled, ARM state
    regs.r[15] = 0x08000000 + 8; // cartridge entry, as a fetch pointer
  }

  int get _opSize => regs.thumb ? 2 : 4;

  /// Executes one instruction and returns its elapsed cycles (>= 1).
  int step() {
    final address = regs.r[15] - _opSize * 2;
    final op = fetch(address);
    final consumed = regs.thumb ? execThumb(op) : execArm(op);
    cycles += consumed;
    return consumed;
  }

  // --- exceptions -----------------------------------------------------------

  // The link values below are what the BIOS handler expects: it returns
  // from SWI/UND via `movs pc, lr` and from IRQ/FIQ/prefetch-abort via
  // `subs pc, lr, #4`, so each link accounts for that. regs.r[15] is
  // the fetch pointer, two instructions past the executing one.
  void raiseUndefined() =>
      enterException(_vectorUndefined, CpuMode.und, regs.r[15] - _opSize);
  void raiseSwi() =>
      enterException(_vectorSwi, CpuMode.svc, regs.r[15] - _opSize);
  void raisePrefetchAbort() => enterException(
      _vectorAbortPrefetch, CpuMode.abt, regs.r[15] - _opSize + 4);
  void raiseDataAbort() =>
      enterException(_vectorAbortData, CpuMode.abt, regs.r[15] - _opSize + 8);

  /// Hardware IRQ line. Called by the bus IRQ controller when IF & IE
  /// != 0 and IME is set; returns true if taken. Taken between
  /// instructions, so the fetch pointer is two instructions past the
  /// instruction that runs on return, and `subs pc, lr, #4` in the
  /// handler lands on it.
  bool irq() {
    if (regs.irqDisabled) return false;
    enterException(_vectorIrq, CpuMode.irq, regs.r[15] - _opSize * 2 + 4);
    return true;
  }

  void fiq() {
    if (regs.fiqDisabled) return;
    enterException(_vectorFiq, CpuMode.fiq, regs.r[15] - _opSize * 2 + 4,
        fiq: true);
  }

  void saveState(StateWriter w) {
    w.section('gba-cpu');
    // The format predates the shared engine: it stores the two
    // prefetched opcodes of the old pipeline model. They are exactly
    // the instructions at the executing address and the one after it,
    // so they are re-fetched here; the pipeline flags are written as
    // the always-valid values the new model implies.
    final size = _opSize;
    final address = regs.r[15] - size * 2;
    w.ints([cycles, fetch(address + size), fetch(address)]);
    for (final b in [shiftCarry, aluCarry, aluOverflow, true, false]) {
      w.boolean(b);
    }
    _saveRegs(w);
  }

  void loadState(StateReader s) {
    s.section('gba-cpu');
    final v = s.ints();
    if (v.length != 3) throw const StateMismatch('gba cpu state layout');
    final flags = [for (var i = 0; i < 5; i++) s.boolean()];
    cycles = v[0];
    // v[1] and v[2] are the old pipeline's prefetched opcodes, which
    // the fetch-pointer model re-fetches instead of restoring; the
    // last two flags described that pipeline and are ignored.
    shiftCarry = flags[0];
    aluCarry = flags[1];
    aluOverflow = flags[2];
    _loadRegs(s);
  }

  void _saveRegs(StateWriter w) {
    w.section('gba-regs');
    w.ints(regs.r);
    w.ints(regs.fiqHigh);
    w.ints(regs.userHigh);
    w.ints([for (var i = 0; i < 6; i++) regs.spLr[i][0]]);
    w.ints([for (var i = 0; i < 6; i++) regs.spLr[i][1]]);
    w.ints(regs.saved);
    w.int32(regs.cpsr);
  }

  void _loadRegs(StateReader s) {
    s.section('gba-regs');
    List<int> read(int length) {
      final v = s.ints();
      if (v.length != length) {
        throw StateMismatch(
            'gba register array of ${v.length} values, expected $length');
      }
      return v;
    }

    final savedR = read(16);
    final savedFiq = read(5);
    final savedUsr = read(5);
    final savedSp = read(6);
    final savedLr = read(6);
    final savedSpsr = read(6);
    final savedCpsr = s.int32();
    regs.r.setAll(0, savedR);
    regs.fiqHigh.setAll(0, savedFiq);
    regs.userHigh.setAll(0, savedUsr);
    for (var i = 0; i < 6; i++) {
      regs.spLr[i][0] = savedSp[i];
      regs.spLr[i][1] = savedLr[i];
    }
    regs.saved.setAll(0, savedSpsr);
    regs.cpsr = savedCpsr;
  }

  String dump() {
    final r = regs.r;
    final flags =
        "${regs.nf ? 'N' : '-'}${regs.zf ? 'Z' : '-'}${regs.cf ? 'C' : '-'}${regs.vf ? 'V' : '-'}";
    final st = regs.thumb ? "T" : "A";
    return "r0:${r[0].x8} r1:${r[1].x8} r2:${r[2].x8} r3:${r[3].x8}\n"
        "r4:${r[4].x8} r5:${r[5].x8} r6:${r[6].x8} r7:${r[7].x8}\n"
        "r8:${r[8].x8} r9:${r[9].x8} sl:${r[10].x8} fp:${r[11].x8}\n"
        "ip:${r[12].x8} sp:${r[13].x8} lr:${r[14].x8} pc:${r[15].x8}\n"
        "cpsr:${regs.cpsr.x8} [$flags $st] mode:${regs.mode.x2}";
  }
}
