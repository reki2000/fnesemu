import 'package:fnesemu/util/int.dart';

import '../bus.dart';
import 'regs.dart';

part 'arm_alu.dart';
part 'arm_isa.dart';
part 'thumb_isa.dart';

/// ARM7TDMI core.
///
/// Implements the ARMv4T instruction set (ARM + THUMB) on top of the
/// register/pipeline scaffolding.
class Arm7 {
  final Bus bus;
  final regs = Regs();

  Arm7(this.bus);

  // carry-out of the barrel shifter, consumed by logical data-processing ops
  bool _shiftC = false;

  // carry / overflow produced by the last arithmetic ALU operation
  bool _aluC = false;
  bool _aluV = false;

  // 2-stage visible prefetch (ARM7 has a 3-stage pipeline: fetch/decode/exec).
  // we model fetched opcodes for the decode/exec stages.
  int _fetched = 0; // opcode at pc (to be decoded next)
  int _decoded = 0; // opcode being executed now
  bool _pipelineValid = false;
  bool _pcDirty = false; // set when a branch/exception refilled the pipeline

  int cycles = 0;

  // exception vector addresses
  static const _vectorReset = 0x00;
  static const _vectorUndefined = 0x04;
  static const _vectorSwi = 0x08;
  static const _vectorAbortPrefetch = 0x0c;
  static const _vectorAbortData = 0x10;
  static const _vectorIrq = 0x18;
  static const _vectorFiq = 0x1c;

  void reset() {
    regs.reset();
    regs.pc = 0x00000000; // BIOS entry
    _flushPipeline();
  }

  /// reset without a real BIOS: emulate the boot sequence the BIOS performs
  /// (set up the SVC/IRQ/SYS stack pointers and jump to the cartridge entry).
  /// Lets polling-based ROMs run without a copyrighted BIOS image.
  void resetHle() {
    regs.reset();
    regs.switchMode(CpuMode.irq);
    regs.r[13] = 0x03007fa0;
    regs.switchMode(CpuMode.svc);
    regs.r[13] = 0x03007fe0;
    regs.switchMode(CpuMode.sys);
    regs.r[13] = 0x03007f00;
    regs.cpsr = CpuMode.sys; // IRQ/FIQ enabled, ARM state
    regs.pc = 0x08000000; // cartridge entry point
    _flushPipeline();
  }

  int get _opSize => regs.thumb ? 2 : 4;

  void _flushPipeline() {
    // align pc and refill the pipeline from the current pc
    final size = _opSize;
    regs.pc = regs.pc & (size == 2 ? ~1 : ~3);
    _decoded = _fetch(regs.pc);
    _fetched = _fetch(regs.pc + size);
    regs.pc = (regs.pc + size * 2).mask32;
    _pipelineValid = true;
    _pcDirty = true;
  }

  int _fetch(int addr) =>
      regs.thumb ? bus.read16(addr & ~1) : bus.read32(addr & ~3);

  /// execute one instruction. returns elapsed cycles (>=1).
  /// stage 1: decode not implemented yet -> raises undefined.
  int step() {
    if (!_pipelineValid) _flushPipeline();

    final size = _opSize;
    final op = _decoded;
    _decoded = _fetched;
    _fetched = _fetch(regs.pc);
    // address of `op` (two opcodes behind the fetch pointer)
    final pcExec = (regs.pc - size * 2).mask32;

    _pcDirty = false; // only a flush *inside* _execute should set this
    final consumed = _execute(op, pcExec);

    if (_pcDirty) {
      _pcDirty = false; // pipeline already points at the next instruction
    } else {
      regs.pc = (regs.pc + size).mask32;
    }
    cycles += consumed;
    return consumed;
  }

  // placeholder dispatcher; Stage 2 implements ARM/THUMB decoders.
  int _execute(int op, int pcExec) {
    return regs.thumb ? _executeThumb(op) : _executeArm(op);
  }

  // --- register / PC helpers ------------------------------------------------

  /// read a register. r15 already reads pipeline-adjusted (instr+8 in ARM,
  /// instr+4 in THUMB) thanks to the prefetch model.
  int _rd(int n) => regs.r[n];

  /// write a register; writing r15 triggers a branch (pipeline flush).
  void _wr(int n, int v) {
    if (n == 15) {
      _setPC(v);
    } else {
      regs.r[n] = v & 0xffffffff;
    }
  }

  /// branch to [addr], aligned to the current instruction width.
  void _setPC(int addr) {
    regs.pc = addr & (regs.thumb ? ~1 : ~3);
    _flushPipeline();
  }

  /// branch-and-exchange: bit0 of [addr] selects THUMB.
  void _bx(int addr) {
    regs.thumb = addr & 1 != 0;
    regs.pc = addr & (regs.thumb ? ~1 : ~3);
    _flushPipeline();
  }

  /// condition-code evaluation for ARM instructions (cond field, bits 31..28).
  bool checkCond(int cond) => switch (cond) {
        0x0 => regs.zf, // EQ
        0x1 => !regs.zf, // NE
        0x2 => regs.cf, // CS
        0x3 => !regs.cf, // CC
        0x4 => regs.nf, // MI
        0x5 => !regs.nf, // PL
        0x6 => regs.vf, // VS
        0x7 => !regs.vf, // VC
        0x8 => regs.cf && !regs.zf, // HI
        0x9 => !regs.cf || regs.zf, // LS
        0xa => regs.nf == regs.vf, // GE
        0xb => regs.nf != regs.vf, // LT
        0xc => !regs.zf && (regs.nf == regs.vf), // GT
        0xd => regs.zf || (regs.nf != regs.vf), // LE
        0xe => true, // AL
        _ => false, // NV (reserved)
      };

  // --- exceptions -----------------------------------------------------------

  // [retAddr] is the value placed in the banked LR. The BIOS handler restores
  // PC from it (SWI/UND via `movs pc,lr`; IRQ/FIQ/prefetch-abort via
  // `subs pc,lr,#4`), so the offsets below account for that.
  void _enterException(int vector, int newMode, int retAddr,
      {bool fiqDisable = false}) {
    final savedCpsr = regs.cpsr;
    regs.switchMode(newMode);
    regs.spsr = savedCpsr;
    regs.r[14] = retAddr.mask32; // lr
    regs.thumb = false;
    regs.irqDisabled = true;
    if (fiqDisable) regs.cpsr = regs.cpsr | 0x40;
    regs.pc = vector;
    _flushPipeline();
  }

  // For SWI/UND the handler returns to the instruction following the offending
  // one (regs.pc points two opcodes ahead, so subtract one opcode width).
  void raiseUndefined() =>
      _enterException(_vectorUndefined, CpuMode.und, regs.pc - _opSize);
  void raiseSwi() => _enterException(_vectorSwi, CpuMode.svc, regs.pc - _opSize);
  void raisePrefetchAbort() =>
      _enterException(_vectorAbortPrefetch, CpuMode.abt, regs.pc - _opSize + 4);
  void raiseDataAbort() =>
      _enterException(_vectorAbortData, CpuMode.abt, regs.pc - _opSize + 8);

  /// hardware IRQ line. called by the bus IRQ controller when IF & IE != 0
  /// and IME is set. returns true if taken. taken between instructions, so
  /// regs.pc points two opcodes past the instruction that runs on return;
  /// `subs pc,lr,#4` in the handler lands on it.
  bool irq() {
    if (regs.irqDisabled) return false;
    _enterException(_vectorIrq, CpuMode.irq, regs.pc - _opSize * 2 + 4);
    return true;
  }

  void fiq() {
    if (regs.fiqDisabled) return;
    _enterException(_vectorFiq, CpuMode.fiq, regs.pc - _opSize * 2 + 4,
        fiqDisable: true);
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
