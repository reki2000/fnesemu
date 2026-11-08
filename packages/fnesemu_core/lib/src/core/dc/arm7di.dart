import 'dart:typed_data';

import '../../components/arm7/arm7.dart';
import '../../components/arm7/regs.dart';
import '../../state.dart';
import '../../util/int.dart';
import 'fault.dart';

/// ARM7DI core (the DC's AICA sound CPU): the ARM7DI embedding of the
/// shared ARM7 engine, based on ARM7DI Data Sheet DDI 0027D.
///
/// The embedding keeps everything ARM7DI-specific: no Thumb and no
/// ARMv4 extensions (the engine faults those encodings in strict mode),
/// the strict reserved/prohibited encoding checks, the early
/// termination multiply timing and the other tuned cycle costs, the
/// direct sound-RAM fast path, the interrupt levels AICA drives, and
/// the save-state format. Cycle totals assume one clock for each
/// S/N/I cycle and no external waits.
class DcArm7di extends Arm7Core {
  /// [memory] is accessed directly; other addresses go through [read]
  /// and [write].
  /// [registers], when given, holds r0-r15, for example in compiled
  /// code's context.
  DcArm7di({
    required this.read,
    required this.write,
    Uint8List? memory,
    super.registers,
  })  : _memory = memory ?? Uint8List(0),
        _words = ByteData.sublistView(memory ?? Uint8List(0)),
        super(
          hasThumb: false,
          armV4: false,
          strict: true,
          onUnsupported: (message) => throw DcUnsupported(message),
        ) {
    reset();
  }

  final int Function(int address, int size) read;
  final void Function(int address, int size, int value) write;
  final Uint8List _memory;
  final ByteData _words;

  @pragma('vm:prefer-inline')
  int _read(int address, int size) {
    if (address >= 0 && address + size <= _memory.length) {
      return size == 1
          ? _memory[address]
          : _words.getUint32(address, Endian.little);
    }
    return read(address, size);
  }

  void _write(int address, int size, int value) {
    if (address >= 0 && address + size <= _memory.length) {
      if (size == 1) {
        _memory[address] = value;
      } else {
        _words.setUint32(address, value & 0xffffffff, Endian.little);
      }
      return;
    }
    write(address, size, value);
  }

  @override
  int fetch(int address) => _read(address, 4);

  @override
  int readMem(int address, int size) => _read(address, size);

  @override
  void writeMem(int address, int size, int value) {
    // The engine passes raw store addresses; the interpreter this
    // replaces aligned word stores at its call sites.
    _write(size == 4 ? address & 0xfffffffc : address, size, value);
  }

  @override
  void onSwi() => enterException(0x08, CpuMode.svc, execPc + 4);

  @override
  void onUndefined() => enterException(0x04, CpuMode.und, execPc + 4);

  @override
  int multiplyCycles(int rsValue) {
    // ARM7DI early termination: the multiplier scans Rs two bits at a
    // time and stops once the remaining bits are all sign extension.
    var iterations = 1;
    while (iterations < 16 && rsValue >= (1 << (2 * iterations - 1))) {
      iterations++;
    }
    return 1 + iterations;
  }

  @override
  int singleLoadCycles(bool toPc) => toPc ? 5 : 3;

  @override
  int blockLoadCycles(int count, bool toPc) => count + (toPc ? 4 : 2);

  @override
  int dataProcCycles(bool registerShift, bool toPc) =>
      (registerShift ? 2 : 1) + (toPc ? 2 : 0);

  @override
  int msrMask(int op, bool toSpsr) {
    // The ARM7DI MSR writes either the flag bits only, or the whole
    // register when bit 16 is set and the write may touch control bits.
    final whole = op & 0x10000 != 0;
    return whole && (toSpsr || regs.mode != CpuMode.usr)
        ? 0xf00000df
        : 0xf0000000;
  }

  @override
  int get cpsrWriteMask => 0xf00000df;

  @override
  void restoreCpsr() => regs.setCpsrBanked(regs.spsr, cpsrWriteMask);

  /// The visible register file (the shared engine's). r[15] holds the
  /// fetch pointer, so the executing address is [pc], 8 below it.
  Uint32List get r => regs.r;

  int get pc => regs.r[15] - 8;
  set pc(int value) => regs.r[15] = (value & 0xfffffffc) + 8;

  int get cpsr => regs.cpsr;
  set cpsr(int value) => regs.setCpsrBanked(value, cpsrWriteMask);

  /// Sets the condition flags of the CPSR.
  set flags(int value) =>
      regs.cpsr = (regs.cpsr & 0x0fffffff) | (value & 0xf0000000);

  int get mode => regs.mode;

  int get spsr => regs.spsr;
  set spsr(int value) => regs.spsr = value;

  int cycles = 0;

  /// Instructions executed, without interrupt entries; not saved.
  int executed = 0;

  /// [cycles] at the start of the instruction that [run] executes.
  int instructionStart = 0;

  /// Makes [run] return after the current instruction.
  bool stop = false;

  bool instructionExecuted = false;
  bool irq = false, fiq = false;

  /// Runs compiled code for up to the given cycles and returns the
  /// cycles it took. Interrupts are accepted by [step] before it is
  /// called.
  int Function(DcArm7di arm, int budget)? compiled;

  void reset() {
    r.fillRange(0, 16, 0);
    regs.userHigh.fillRange(0, 5, 0);
    regs.fiqHigh.fillRange(0, 5, 0);
    for (final bank in regs.spLr) {
      bank.fillRange(0, 2, 0);
    }
    regs.saved.fillRange(0, 6, 0);
    regs.cpsr = 0xd3;
    regs.r[15] = 8; // fetch pointer for address 0
    cycles = 0;
    instructionExecuted = false;
    irq = fiq = false;
  }

  /// Steps while [cycles] is below [end] and nothing sets [stop].
  void run(int end) {
    stop = false;
    final compiled = this.compiled;
    while (cycles < end) {
      if (compiled != null &&
          !(fiq && !regs.fiqDisabled) &&
          !(irq && !regs.irqDisabled)) {
        final spent = compiled(this, end - cycles);
        if (spent > 0) {
          cycles += spent;
          executed++;
          if (cycles >= end) return;
        }
      }
      // The instruction compiled code left, or one not yet compiled.
      instructionStart = cycles;
      step();
      if (stop) return;
    }
  }

  /// Executes one instruction, or accepts one interrupt before
  /// fetching.
  int step() {
    instructionExecuted = false;
    if (fiq && !regs.fiqDisabled) {
      enterException(0x1c, CpuMode.fiq, pc + 4, fiq: true);
      cycles += 3;
      return 3;
    }
    if (irq && !regs.irqDisabled) {
      enterException(0x18, CpuMode.irq, pc + 4);
      cycles += 3;
      return 3;
    }
    final op = _read(pc, 4).mask32;
    final cost = execArm(op);
    cycles += cost;
    instructionExecuted = true;
    executed++;
    return cost;
  }

  List<List<int>> get _stateBanks => [
        // The serialized r15 is the executing address, not the fetch
        // pointer the register file holds.
        [for (var i = 0; i < 15; i++) r[i], pc],
        regs.userHigh,
        regs.fiqHigh,
        ...regs.spLr,
        regs.saved,
      ];

  /// Instruction-boundary state; memory and bus callbacks belong to
  /// AICA.
  void saveState(StateWriter writer) {
    writer.section('dc.arm7di');
    for (final bank in _stateBanks) {
      writer.ints(bank);
    }
    writer.int32(cpsr);
    writer.int64(cycles);
    writer.boolean(instructionExecuted);
    writer.boolean(irq);
    writer.boolean(fiq);
  }

  void loadState(StateReader reader) {
    reader.section('dc.arm7di');
    final banks = _stateBanks;
    final values = [for (final _ in banks) reader.ints()];
    final status = reader.int32() & 0xffffffff;
    final elapsed = reader.int64();
    final executed = reader.boolean(),
        irqLevel = reader.boolean(),
        fiqLevel = reader.boolean();
    for (var i = 0; i < banks.length; i++) {
      if (values[i].length != banks[i].length ||
          values[i].any((value) => value < 0 || value > 0xffffffff)) {
        throw const StateMismatch('ARM7DI register bank');
      }
    }
    if (status & ~0xf00000df != 0 ||
        !const [0x10, 0x11, 0x12, 0x13, 0x17, 0x1b].contains(status & 31) ||
        values[0][15] & 3 != 0 ||
        elapsed < 0) {
      throw const StateMismatch('ARM7DI control state');
    }
    regs.r.setAll(0, values[0]);
    regs.r[15] = values[0][15] + 8; // executing address to fetch pointer
    regs.userHigh.setAll(0, values[1]);
    regs.fiqHigh.setAll(0, values[2]);
    for (var i = 0; i < 6; i++) {
      regs.spLr[i].setAll(0, values[3 + i]);
    }
    regs.saved.setAll(0, values[9]);
    // Assign directly: the banking setter would overwrite restored
    // banks.
    regs.cpsr = status;
    cycles = elapsed;
    instructionExecuted = executed;
    irq = irqLevel;
    fiq = fiqLevel;
  }

  /// Logical state for debugger loop detection, excluding elapsed
  /// clocks.
  List<int> get debugState => [
        for (var i = 0; i < 15; i++) r[i],
        pc,
        cpsr,
        ...regs.userHigh,
        ...regs.fiqHigh,
        for (final bank in regs.spLr) ...bank,
        ...regs.saved,
        irq ? 1 : 0,
        fiq ? 1 : 0,
      ];
}
