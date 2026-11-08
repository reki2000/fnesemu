import 'dart:math';
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/gba/arm7tdmi/arm7.dart';
import 'package:fnesemu_core/src/core/gba/arm_jit.dart';
import 'package:fnesemu_core/src/core/gba/bus.dart';
import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

// JIT versus interpreter comparison for the GBA core, in the style of
// the PS and PS2 JIT tests: the same program runs on an interpreter
// machine and on machines whose CPU shares its registers with a
// GbaJit (the reference IR runtime and, when the host has one, the
// native runtime), and the full architectural state and memory must
// agree. Cycle counts are compared only for programs without failing
// conditions: compiled code charges a predicated instruction's full
// cost where the interpreter charges one cycle, the ARM7DI
// translator's documented divergence.

const _code = 0x03000000; // IWRAM
const _dataI = 0x03004000; // IWRAM data page
const _dataE = 0x02000000; // EWRAM data page
const _stack = 0x03007e00;

final class _Machine {
  final Bus bus;
  final Arm7 cpu;
  final GbaJit? jit;

  _Machine._(this.bus, this.cpu, this.jit);

  factory _Machine.interpreter() {
    final bus = Bus();
    return _Machine._(bus, Arm7(bus), null);
  }

  factory _Machine.jit(GbaJit jit) {
    final bus = Bus(ewram: jit.ewram, iwram: jit.iwram);
    final cpu = Arm7(bus, registers: jit.registers);
    jit.attach(bus);
    return _Machine._(bus, cpu, jit);
  }

  /// Loads an ARM program and the shared data image, and sets up the
  /// CPU in system mode with the data base registers the generated
  /// programs use (r10 = IWRAM data, r11 = EWRAM data).
  void loadArm(List<int> program, Uint8List data) {
    for (final (i, word) in program.indexed) {
      bus.write32(_code + 4 * i, word);
    }
    bus.iwram.setAll(_dataI - _code, data);
    bus.ewram.setAll(0, data);
    cpu.regs.cpsr = 0x1f; // system mode, ARM state
    cpu.regs.r[13] = _stack;
    cpu.regs.r[10] = _dataI;
    cpu.regs.r[11] = _dataE;
    cpu.regs.r[15] = _code + 8;
  }

  /// Loads a Thumb program; the CPU starts in Thumb state.
  void loadThumb(List<int> program, Uint8List data) {
    for (final (i, half) in program.indexed) {
      bus.write16(_code + 2 * i, half);
    }
    bus.iwram.setAll(_dataI - _code, data);
    bus.ewram.setAll(0, data);
    cpu.regs.cpsr = 0x3f; // system mode, Thumb state
    cpu.regs.r[13] = _stack;
    cpu.regs.r[10] = _dataI;
    cpu.regs.r[11] = _dataE;
    cpu.regs.r[15] = _code + 4;
  }

  /// Runs until the CPU reaches [end] (the program's halt loop).
  void runTo(int end) {
    var guard = 0;
    while (cpu.pc != end) {
      if (++guard > 200000) fail('the program did not finish');
      final jit = this.jit;
      if (jit == null) {
        cpu.step();
      } else if (jit.run(cpu, 100000) == 0) {
        cpu.step();
      }
    }
  }

  /// The full architectural state: visible and banked registers and
  /// the CPSR.
  List<int> get state => [
        ...cpu.regs.r,
        cpu.regs.cpsr,
        ...cpu.regs.fiqHigh,
        ...cpu.regs.userHigh,
        for (final bank in cpu.regs.spLr) ...bank,
        ...cpu.regs.saved,
      ];
}

/// Runs an ARM [program] on the interpreter and on every available
/// JIT backend and expects identical state and memory. [cycles] also
/// compares the cycle counts (see the file doc).
void _compareArm(List<int> program, {Uint8List? data, bool cycles = false}) {
  data ??= _seedData();
  final end = _code + 4 * (program.length - 1);
  final ref = _Machine.interpreter()
    ..loadArm(program, data)
    ..runTo(end);
  for (final jit in _jits()) {
    final machine = _Machine.jit(jit)
      ..loadArm(program, data)
      ..runTo(end);
    _expectSame(ref, machine, cycles: cycles);
    jit.dispose();
  }
}

void _compareThumb(List<int> program, {Uint8List? data, bool cycles = false}) {
  data ??= _seedData();
  final end = _code + 2 * (program.length - 1);
  final ref = _Machine.interpreter()
    ..loadThumb(program, data)
    ..runTo(end);
  for (final jit in _jits()) {
    final machine = _Machine.jit(jit)
      ..loadThumb(program, data)
      ..runTo(end);
    _expectSame(ref, machine, cycles: cycles);
    jit.dispose();
  }
}

void _expectSame(_Machine ref, _Machine machine, {required bool cycles}) {
  expect(machine.state, ref.state, reason: 'register state differs');
  expect(machine.bus.iwram, ref.bus.iwram, reason: 'IWRAM differs');
  expect(machine.bus.ewram, ref.bus.ewram, reason: 'EWRAM differs');
  if (cycles) {
    expect(machine.cpu.cycles, ref.cpu.cycles, reason: 'cycles differ');
  }
}

List<GbaJit> _jits() => [
      if (JitRuntime.nativeSupported) GbaJit.create()!,
      GbaJit.create(native: false)!,
    ];

Uint8List _seedData() {
  final rnd = Random(0x9a17);
  return Uint8List.fromList([for (var i = 0; i < 0x400; i++) rnd.nextInt(256)]);
}

// --- ARM encoders -----------------------------------------------------------

int _dpI(int cond, int opcode, bool s, int rn, int rd, int rotImm) =>
    (cond << 28) |
    (1 << 25) |
    (opcode << 21) |
    (s ? 1 << 20 : 0) |
    (rn << 16) |
    (rd << 12) |
    rotImm;

int _dpS(int cond, int opcode, bool s, int rn, int rd, int amount, int type,
        int rm) =>
    (cond << 28) |
    (opcode << 21) |
    (s ? 1 << 20 : 0) |
    (rn << 16) |
    (rd << 12) |
    (amount << 7) |
    (type << 5) |
    rm;

int _dpR(int cond, int opcode, bool s, int rn, int rd, int rs, int type,
        int rm) =>
    (cond << 28) |
    (opcode << 21) |
    (s ? 1 << 20 : 0) |
    (rn << 16) |
    (rd << 12) |
    (rs << 8) |
    (type << 5) |
    0x10 |
    rm;

/// A rotated-imm8 operand2 for an encodable [value].
int _imm(int value) {
  for (var rot = 0; rot < 16; rot++) {
    final n = rot * 2;
    final imm8 = ((value << n) | (value >> (32 - n))) & 0xffffffff;
    if (imm8 <= 0xff) return (rot << 8) | imm8;
  }
  throw ArgumentError('not encodable: $value');
}

int _mov(int rd, int value, {bool s = false}) =>
    _dpI(14, 13, s, 0, rd, _imm(value));
int _add(int rd, int rn, int value, {bool s = false}) =>
    _dpI(14, 4, s, rn, rd, _imm(value));
int _sub(int rd, int rn, int value, {bool s = false}) =>
    _dpI(14, 2, s, rn, rd, _imm(value));
int _movR(int rd, int rm, {bool s = false}) => _dpS(14, 13, s, 0, rd, 0, 0, rm);

int _mul(int cond, bool acc, bool s, int rd, int rn, int rs, int rm) =>
    (cond << 28) |
    (acc ? 1 << 21 : 0) |
    (s ? 1 << 20 : 0) |
    (rd << 16) |
    (rn << 12) |
    (rs << 8) |
    0x90 |
    rm;

int _mulL(int cond, bool sign, bool acc, bool s, int rdHi, int rdLo, int rs,
        int rm) =>
    (cond << 28) |
    (1 << 23) |
    (sign ? 1 << 22 : 0) |
    (acc ? 1 << 21 : 0) |
    (s ? 1 << 20 : 0) |
    (rdHi << 16) |
    (rdLo << 12) |
    (rs << 8) |
    0x90 |
    rm;

int _swap(int cond, bool byte, int rn, int rd, int rm) =>
    (cond << 28) |
    (1 << 24) |
    (byte ? 1 << 22 : 0) |
    (rn << 16) |
    (rd << 12) |
    0x90 |
    rm;

/// Single transfer, immediate offset.
int _tr(int cond,
        {required bool pre,
        required bool up,
        required bool byte,
        required bool wb,
        required bool load,
        required int rn,
        required int rd,
        required int offset}) =>
    (cond << 28) |
    (1 << 26) |
    (pre ? 1 << 24 : 0) |
    (up ? 1 << 23 : 0) |
    (byte ? 1 << 22 : 0) |
    (wb ? 1 << 21 : 0) |
    (load ? 1 << 20 : 0) |
    (rn << 16) |
    (rd << 12) |
    offset;

/// Single transfer, register offset with an immediate shift.
int _trR(int cond,
        {required bool pre,
        required bool up,
        required bool byte,
        required bool wb,
        required bool load,
        required int rn,
        required int rd,
        required int amount,
        required int type,
        required int rm}) =>
    (cond << 28) |
    (1 << 26) |
    (1 << 25) |
    (pre ? 1 << 24 : 0) |
    (up ? 1 << 23 : 0) |
    (byte ? 1 << 22 : 0) |
    (wb ? 1 << 21 : 0) |
    (load ? 1 << 20 : 0) |
    (rn << 16) |
    (rd << 12) |
    (amount << 7) |
    (type << 5) |
    rm;

/// Halfword transfer; [sh] is 1=H, 2=signed byte, 3=signed halfword.
int _trH(int cond,
        {required bool pre,
        required bool up,
        required bool wb,
        required bool load,
        required int rn,
        required int rd,
        required int sh,
        int imm = 0,
        int rm = -1}) =>
    (cond << 28) |
    (pre ? 1 << 24 : 0) |
    (up ? 1 << 23 : 0) |
    (rm < 0 ? 1 << 22 : 0) |
    (wb ? 1 << 21 : 0) |
    (load ? 1 << 20 : 0) |
    (rn << 16) |
    (rd << 12) |
    ((imm >> 4) << 8) |
    0x90 |
    (sh << 5) |
    (rm < 0 ? imm & 15 : rm);

int _block(int cond,
        {required bool pre,
        required bool up,
        required bool wb,
        required bool load,
        required int rn,
        required List<int> regs}) =>
    (cond << 28) |
    (1 << 27) |
    (pre ? 1 << 24 : 0) |
    (up ? 1 << 23 : 0) |
    (wb ? 1 << 21 : 0) |
    (load ? 1 << 20 : 0) |
    (rn << 16) |
    [for (final r in regs) 1 << r].fold(0, (a, b) => a | b);

/// Branch from instruction index [from] to index [to] in the program.
int _b(int cond, int from, int to, {bool link = false}) =>
    (cond << 28) |
    (5 << 25) |
    (link ? 1 << 24 : 0) |
    ((to - from - 2) & 0xffffff);

int _mrs(int rd, {bool spsr = false}) =>
    (14 << 28) | (1 << 24) | (spsr ? 1 << 22 : 0) | (1 << 21) | (15 << 16) | (rd << 12);

/// MSR to CPSR fields [mask] (bit per field byte) from register [rm].
int _msr(int mask, int rm, {bool spsr = false}) =>
    (14 << 28) |
    (1 << 24) |
    (spsr ? 1 << 22 : 0) |
    (1 << 21) |
    (mask << 16) |
    (15 << 12) |
    rm;

const _halt = 0xea000000 - 2; // b .

/// Generates a bounded random ARM program: a fixed loop whose body
/// mixes data processing (all operand forms), multiply, single and
/// halfword transfers, swaps and block transfers over the seeded data
/// pages. r9 is the loop counter; r8 is a scratch base the generator
/// reloads before writeback transfers, swaps and block transfers, so
/// generated addresses stay inside the data pages.
List<int> _randomArmProgram(Random rnd) {
  final body = <int>[];
  int reg() => rnd.nextInt(8);
  int base() => rnd.nextBool() ? 10 : 11;
  final encodable = [
    0, 1, 2, 3, 7, 8, 15, 16, 31, 32, 63, 64, 100, 127, 128, 255, 256,
    0x1000, 0xff00, 0x80000000, 0x7f000000
  ];
  int imm() => _imm(encodable[rnd.nextInt(encodable.length)]);

  void reloadBase() => body.add(_movR(8, 10));

  void emit() {
    switch (rnd.nextInt(24)) {
      case 0:
      case 1:
      case 2:
      case 3: // data processing, immediate
        final opcode = rnd.nextInt(16);
        final test = opcode >= 8 && opcode <= 11;
        body.add(_dpI(rnd.nextInt(4) == 0 ? rnd.nextInt(15) : 14, opcode,
            test || rnd.nextBool(), reg(), test ? 0 : reg(), imm()));
      case 4:
      case 5:
      case 6: // data processing, immediate shift
        final opcode = rnd.nextInt(16);
        final test = opcode >= 8 && opcode <= 11;
        body.add(_dpS(14, opcode, test || rnd.nextBool(), reg(),
            test ? 0 : reg(), rnd.nextInt(32), rnd.nextInt(4), reg()));
      case 7:
      case 8: // data processing, register shift
        final opcode = rnd.nextInt(16);
        final test = opcode >= 8 && opcode <= 11;
        body.add(_dpR(14, opcode, test || rnd.nextBool(), reg(),
            test ? 0 : reg(), reg(), rnd.nextInt(4), reg()));
      case 9: // multiply
        if (rnd.nextBool()) {
          body.add(_mul(14, rnd.nextBool(), rnd.nextBool(), reg(), reg(),
              reg(), reg()));
        } else {
          final hi = reg(), lo = (hi + 1 + rnd.nextInt(6)) % 8;
          body.add(_mulL(14, rnd.nextBool(), rnd.nextBool(), rnd.nextBool(),
              hi, lo, reg(), reg()));
        }
      case 10:
      case 11:
      case 12: // single transfer, no writeback
        body.add(_tr(14,
            pre: rnd.nextBool(),
            up: rnd.nextBool(),
            byte: rnd.nextBool(),
            wb: false,
            load: rnd.nextBool(),
            rn: base(),
            rd: reg(),
            offset: rnd.nextInt(0x50) * 4));
      case 13: // single transfer with writeback on the scratch base
        reloadBase();
        body.add(_tr(14,
            pre: rnd.nextBool(),
            up: rnd.nextBool(),
            byte: rnd.nextBool(),
            wb: true,
            load: rnd.nextBool(),
            rn: 8,
            rd: reg(),
            offset: rnd.nextInt(3) * 4));
      case 14:
      case 15: // halfword transfer
        final load = rnd.nextBool();
        body.add(_trH(14,
            pre: rnd.nextBool(),
            up: rnd.nextBool(),
            wb: false,
            load: load,
            rn: base(),
            rd: reg(),
            sh: load ? 1 + rnd.nextInt(3) : 1,
            imm: rnd.nextInt(0x30)));
      case 16: // swap
        reloadBase();
        body.add(_swap(14, rnd.nextBool(), 8, reg(), reg()));
      case 17: // block transfer
        reloadBase();
        final regs = <int>{
          for (var i = 0; i < 6; i++)
            if (rnd.nextBool()) i
        }.toList();
        if (regs.isEmpty) regs.add(0);
        body.add(_block(14,
            pre: rnd.nextBool(),
            up: rnd.nextBool(),
            wb: true,
            load: rnd.nextBool(),
            rn: 8,
            regs: regs));
      case 18: // register-offset transfer; rm is r0, bounded first
        body.add(_dpI(14, 0, false, 0, 0, _imm(0x3c))); // and r0, r0, #0x3c
        body.add(_trR(14,
            pre: rnd.nextBool(),
            up: true,
            byte: rnd.nextBool(),
            wb: false,
            load: rnd.nextBool(),
            rn: base(),
            rd: reg(),
            amount: rnd.nextInt(4),
            type: 0,
            rm: 0));
      default: // plain register move / add chain
        body.add(_dpS(14, rnd.nextBool() ? 13 : 4, rnd.nextBool(), reg(),
            reg(), 0, 0, reg()));
    }
  }

  final count = 40 + rnd.nextInt(40);
  // A forward conditional skip must land inside the body: only emit
  // one when enough instructions certainly remain.
  for (var i = 0; i < count; i++) {
    final skip = 1 + rnd.nextInt(3);
    if (rnd.nextInt(12) == 0 && skip < count - i - 1) {
      body.add(_b(rnd.nextInt(14), body.length, body.length + skip));
    }
    emit();
  }
  return [
    _mov(9, 5),
    ...body,
    _sub(9, 9, 1, s: true),
    _b(1, body.length + 2, 1),
    _halt,
  ];
}

// --- Thumb encoders ---------------------------------------------------------

int _tShift(int type, int offset, int rs, int rd) =>
    (type << 11) | (offset << 6) | (rs << 3) | rd;
int _tAddSub(int rn, int rs, int rd, {bool sub = false, bool imm = false}) =>
    0x1800 | (sub ? 1 << 9 : 0) | (imm ? 1 << 10 : 0) | (rn << 6) | (rs << 3) | rd;
int _tImm(int kind, int rd, int imm8) => 0x2000 | (kind << 11) | (rd << 8) | imm8;
int _tAlu(int opcode, int rs, int rd) => 0x4000 | (opcode << 6) | (rs << 3) | rd;
int _tHi(int opcode, int rs, int rd) =>
    0x4400 |
    (opcode << 8) |
    ((rd & 8) << 4) |
    ((rs & 8) << 3) |
    ((rs & 7) << 3) |
    (rd & 7);
int _tBx(int rs) => 0x4700 | (rs << 3);
int _tLdrPc(int rd, int imm8) => 0x4800 | (rd << 8) | imm8;
int _tLdStR(int ro, int rb, int rd, {required bool load, required bool byte}) =>
    0x5000 | (load ? 1 << 11 : 0) | (byte ? 1 << 10 : 0) | (ro << 6) | (rb << 3) | rd;
int _tLdStS(int ro, int rb, int rd, {required bool h, required bool s}) =>
    0x5200 | (h ? 1 << 11 : 0) | (s ? 1 << 10 : 0) | (ro << 6) | (rb << 3) | rd;
int _tLdStI(int offset, int rb, int rd, {required bool load, required bool byte}) =>
    0x6000 |
    (byte ? 1 << 12 : 0) |
    (load ? 1 << 11 : 0) |
    (offset << 6) |
    (rb << 3) |
    rd;
int _tLdStH(int offset, int rb, int rd, {required bool load}) =>
    0x8000 | (load ? 1 << 11 : 0) | (offset << 6) | (rb << 3) | rd;
int _tLdStSp(int rd, int imm8, {required bool load}) =>
    0x9000 | (load ? 1 << 11 : 0) | (rd << 8) | imm8;
int _tAddr(int rd, int imm8, {bool sp = false}) =>
    0xa000 | (sp ? 1 << 11 : 0) | (rd << 8) | imm8;
int _tAddSp(int imm7, {bool sub = false}) => 0xb000 | (sub ? 1 << 7 : 0) | imm7;
int _tPushPop(List<int> regs, {required bool load, bool extra = false}) =>
    0xb400 |
    (load ? 1 << 11 : 0) |
    (extra ? 1 << 8 : 0) |
    [for (final r in regs) 1 << r].fold(0, (a, b) => a | b);
int _tBlock(int rb, List<int> regs, {required bool load}) =>
    0xc000 |
    (load ? 1 << 11 : 0) |
    (rb << 8) |
    [for (final r in regs) 1 << r].fold(0, (a, b) => a | b);
int _tBcond(int cond, int from, int to) =>
    0xd000 | (cond << 8) | ((to - from - 2) & 0xff);
int _tB(int from, int to) => 0xe000 | ((to - from - 2) & 0x7ff);
int _tBl(int from, int to) {
  final offset = (to - from - 2) * 2;
  return ((0xf000 | ((offset >> 12) & 0x7ff)) << 16) |
      (0xf800 | ((offset >> 1) & 0x7ff));
}

const _tHalt = 0xe7fe; // b .

/// Generates a bounded random Thumb program: a fixed loop whose
/// body mixes immediate and ALU operations, shifts (immediate and by
/// register), and every load/store format over the seeded data pages.
/// r7 is the loop counter; r4/r5 are the data bases, reloaded from
/// r10/r11 at the loop head because block transfers write them back;
/// r6 is a bounded register offset.
List<int> _randomThumbProgram(Random rnd) {
  final body = <int>[];
  int reg() => rnd.nextInt(4);
  int base() => 4 + rnd.nextInt(2);

  void emit() {
    switch (rnd.nextInt(20)) {
      case 0:
      case 1:
      case 2: // immediate operations
        body.add(_tImm(rnd.nextInt(4), reg(), rnd.nextInt(256)));
      case 3:
      case 4: // immediate shifts
        body.add(_tShift(rnd.nextInt(3), rnd.nextInt(32), reg(), reg()));
      case 5:
      case 6: // add/subtract, register or imm3
        body.add(_tAddSub(rnd.nextInt(8), reg(), reg(),
            sub: rnd.nextBool(), imm: rnd.nextBool()));
      case 7:
      case 8:
      case 9: // ALU, including register shifts and multiply
        body.add(_tAlu(rnd.nextInt(16), reg(), reg()));
      case 10:
      case 11: // load/store, immediate offset
        body.add(_tLdStI(rnd.nextInt(32), base(), reg(),
            load: rnd.nextBool(), byte: rnd.nextBool()));
      case 12: // load/store halfword
        body.add(
            _tLdStH(rnd.nextInt(32), base(), reg(), load: rnd.nextBool()));
      case 13: // load/store, register offset (r6 bounded by the mov)
        body.add(_tImm(0, 6, rnd.nextInt(200)));
        if (rnd.nextBool()) {
          body.add(_tLdStR(6, base(), reg(),
              load: rnd.nextBool(), byte: rnd.nextBool()));
        } else {
          body.add(
              _tLdStS(6, base(), reg(), h: rnd.nextBool(), s: rnd.nextBool()));
        }
      case 14: // SP-relative load/store (the harness stack area)
        body.add(_tLdStSp(reg(), rnd.nextInt(64), load: rnd.nextBool()));
      case 15: // block transfer over a data base
        final regs = <int>{
          for (var i = 0; i < 4; i++)
            if (rnd.nextBool()) i
        }.toList();
        if (regs.isEmpty) regs.add(0);
        body.add(_tBlock(base(), regs, load: rnd.nextBool()));
      case 16: // balanced push/pop around a few ALU operations
        final regs = <int>{
          for (var i = 0; i < 4; i++)
            if (rnd.nextBool()) i
        }.toList();
        if (regs.isEmpty) regs.add(0);
        body.add(_tPushPop(regs, load: false));
        body.add(_tAlu(rnd.nextInt(16), reg(), reg()));
        body.add(_tPushPop(regs, load: true));
      case 17: // load address (pc/sp-relative arithmetic)
        body.add(_tAddr(reg(), rnd.nextInt(64), sp: rnd.nextBool()));
      default: // hi-register moves between low regs and the bases
        body.add(_tHi(2, reg(), 4 + rnd.nextInt(2)));
    }
  }

  // The body's length is bounded so the loop branch's 8-bit offset
  // reaches the head; a forward skip must land inside the body.
  final target = 60 + rnd.nextInt(30);
  while (body.length < target) {
    final skip = 1 + rnd.nextInt(3);
    if (rnd.nextInt(12) == 0 && body.length + skip < target - 2) {
      body.add(_tBcond(rnd.nextInt(14), body.length, body.length + skip));
    }
    emit();
  }
  // Indices: 0 counter, 1-2 loop head (base reloads), body at 3..,
  // then subs / bne / halt.
  return [
    _tImm(0, 7, 5),
    _tHi(2, 10, 4),
    _tHi(2, 11, 5),
    ...body,
    _tImm(3, 7, 1),
    _tBcond(1, body.length + 4, 1),
    _tHalt,
  ];
}

void main() {
  group('random ARM programs', () {
    for (var seed = 1; seed <= 10; seed++) {
      test('seed $seed', () {
        _compareArm(_randomArmProgram(Random(seed * 7919)));
      });
    }
  });

  group('random Thumb programs', () {
    for (var seed = 1; seed <= 10; seed++) {
      test('seed $seed', () {
        _compareThumb(_randomThumbProgram(Random(seed * 104729)));
      });
    }
  });

  group('directed ARM programs', () {
    test('data processing, flags and conditional execution', () {
      _compareArm([
        _dpI(14, 15, false, 0, 0, _imm(0x80000000)), // mvn r0, #0x80000000 -> 0x7fffffff
        _add(0, 0, 1, s: true), // overflows: N=1, V=1
        _dpI(14, 2, true, 0, 1, _imm(0x80000000)), // subs r1, r0, #0x80000000
        _dpS(14, 5, true, 1, 2, 0, 0, 0), // adc r2, r1, r0
        _dpI(14, 6, true, 2, 3, _imm(1)), // sbc r3, r2, #1
        _dpI(14, 3, true, 3, 4, _imm(0xff)), // rsb r4, r3, #0xff
        _dpS(14, 7, true, 4, 5, 0, 0, 3), // rsc r5, r4, r3
        _dpI(14, 8, true, 5, 0, _imm(0x0f)), // tst r5, #0x0f
        _dpS(14, 9, true, 5, 0, 0, 0, 2), // teq r5, r2
        _dpI(14, 10, true, 5, 0, _imm(0x55)), // cmp r5, #0x55
        _dpI(14, 11, true, 5, 0, _imm(0x55)), // cmn r5, #0x55
        _dpI(14, 0, true, 5, 6, _imm(0xf0)), // and r6, r5, #0xf0
        _dpS(14, 1, true, 6, 7, 0, 0, 1), // eor r7, r6, r1
        _dpI(14, 12, true, 7, 8, _imm(0xf000)), // orr r8, r7, #0x0f0f
        _dpI(14, 14, true, 8, 9, _imm(0xff)), // bic r9, r8, #0xff
        _dpS(14, 15, true, 0, 12, 0, 0, 9), // mvn r12, r9
        _dpI(2, 13, false, 0, 0, _imm(0x120)), // movcs r0 (C=0: skipped)
        _dpI(3, 13, false, 0, 1, _imm(0x120)), // movcc r1 (taken)
        _halt,
      ]);
    });

    test('immediate shifts of every type and amount', () {
      final program = <int>[_mov(4, 0), _mov(5, 0), _mov(6, 0), _mov(7, 0)];
      for (var type = 0; type < 4; type++) {
        for (final amount in [0, 1, 13, 31]) {
          program.add(_tr(14,
              pre: true, up: true, byte: false, wb: false, load: true,
              rn: 10, rd: 1, offset: (type * 4 + (amount % 4)) * 4));
          program.add(_dpS(14, 13, true, 0, 2, amount, type, 1));
          program.add(_dpS(14, 4, false, 4 + type, 4 + type, 0, 0, 2));
        }
      }
      program.add(_halt);
      _compareArm(program, cycles: true);
    });

    test('register-controlled shifts, including amounts over 31', () {
      final program = <int>[_mov(4, 0), _mov(5, 0), _mov(6, 0), _mov(7, 0)];
      for (final (i, amount) in [0, 1, 5, 31, 32, 33, 63, 255].indexed) {
        program.add(_mov(0, amount));
        program.add(_tr(14,
            pre: true, up: true, byte: false, wb: false, load: true,
            rn: 10, rd: 1, offset: i * 4));
        for (var type = 0; type < 4; type++) {
          program.add(_dpR(14, 13, true, 0, 2, 0, type, 1));
          program.add(_dpS(14, 4, false, 4 + type, 4 + type, 0, 0, 2));
        }
      }
      program.add(_halt);
      _compareArm(program);
    });

    test('multiply and long multiply', () {
      _compareArm([
        _tr(14, pre: true, up: true, byte: false, wb: false, load: true, rn: 10, rd: 0, offset: 0),
        _tr(14, pre: true, up: true, byte: false, wb: false, load: true, rn: 10, rd: 1, offset: 4),
        _mul(14, false, false, 2, 0, 1, 0), // mul r2, r0, r1
        _mul(14, true, false, 4, 5, 0, 2), // mla r4, r2, r0, r5
        _mul(14, false, true, 6, 0, 1, 0), // muls r6, r0, r1
        _mul(14, false, false, 3, 0, 0, 0), // mul r3, r0, r0 (rd == rm shape)
        _mulL(14, false, false, false, 9, 8, 1, 0), // umull r8, r9, r0, r1
        _mulL(14, false, true, false, 9, 8, 1, 1), // umlal r8, r9, r1, r1
        _mulL(14, true, false, true, 7, 6, 0, 1), // smulls r6, r7, r1, r0
        _mulL(14, true, true, false, 7, 6, 1, 1), // smlal r6, r7, r1, r1
        _halt,
      ], cycles: true);
    });

    test('single transfers in every addressing mode', () {
      final program = <int>[
        _tr(14, pre: true, up: true, byte: false, wb: false, load: true, rn: 10, rd: 0, offset: 0),
        _tr(14, pre: true, up: true, byte: false, wb: false, load: false, rn: 11, rd: 0, offset: 0x40),
        _tr(14, pre: true, up: true, byte: true, wb: false, load: false, rn: 11, rd: 0, offset: 0x45),
        _tr(14, pre: true, up: true, byte: true, wb: false, load: true, rn: 11, rd: 1, offset: 0x45),
        _tr(14, pre: true, up: true, byte: false, wb: false, load: true, rn: 11, rd: 2, offset: 0x42), // unaligned: rotates
        _tr(14, pre: true, up: true, byte: false, wb: true, load: true, rn: 11, rd: 3, offset: 4), // writeback
        _tr(14, pre: false, up: true, byte: false, wb: false, load: false, rn: 11, rd: 3, offset: 4), // post-index store
        _tr(14, pre: false, up: false, byte: false, wb: false, load: true, rn: 11, rd: 4, offset: 8), // post-index down
        _tr(14, pre: true, up: false, byte: false, wb: true, load: true, rn: 11, rd: 5, offset: 12), // pre-index down with writeback
        _movR(6, 11),
        _mov(8, 3),
        _trR(14, pre: true, up: true, byte: false, wb: false, load: true, rn: 6, rd: 7, amount: 2, type: 0, rm: 8), // register offset, shifted
        _trR(14, pre: false, up: true, byte: true, wb: false, load: false, rn: 6, rd: 7, amount: 0, type: 0, rm: 1),
        _tr(14, pre: true, up: true, byte: false, wb: false, load: false, rn: 11, rd: 15, offset: 0x80), // str pc (stores pc + 12)
        _tr(14, pre: true, up: true, byte: false, wb: false, load: true, rn: 11, rd: 8, offset: 0x80),
        _halt,
      ];
      _compareArm(program, cycles: true);
    });

    test('loads to PC branch', () {
      // ldr pc, [r11, #off] jumps over the next instructions into the
      // tail; the skipped instructions would corrupt r0.
      final program = <int>[
        _mov(0, 0), // 0
        _movR(1, 1), // 1
        _tr(14, pre: true, up: true, byte: false, wb: false, load: true, rn: 11, rd: 15, offset: 0x100), // 2: ldr pc
        _mov(0, 0xee000000), // 3 (skipped)
        _mov(0, 0xee000000), // 4 (skipped)
        _add(0, 0, 1), // 5: landing pad
        _halt, // 6
      ];
      final data = _seedData();
      data.buffer.asByteData().setUint32(0x100, _code + 4 * 5, Endian.little);
      _compareArm(program, data: data, cycles: true);
    });

    test('halfword and signed transfers, aligned and odd', () {
      final program = <int>[
        for (var i = 0; i < 8; i++)
          _trH(14, pre: true, up: true, wb: false, load: true, rn: 10, rd: i % 4, sh: 1, imm: i),
        _trH(14, pre: true, up: true, wb: false, load: true, rn: 10, rd: 4, sh: 2, imm: 3), // ldrsb odd
        _trH(14, pre: true, up: true, wb: false, load: true, rn: 10, rd: 5, sh: 3, imm: 3), // ldrsh odd
        _trH(14, pre: true, up: true, wb: false, load: true, rn: 10, rd: 6, sh: 3, imm: 4), // ldrsh even
        _trH(14, pre: true, up: true, wb: false, load: true, rn: 10, rd: 7, sh: 2, imm: 0), // ldrsb
        _tr(14, pre: true, up: true, byte: false, wb: false, load: true, rn: 10, rd: 0, offset: 0x20), // ldr r0 (store value)
        _trH(14, pre: true, up: true, wb: false, load: false, rn: 11, rd: 0, sh: 1, imm: 0x21), // strh odd address
        _trH(14, pre: false, up: true, wb: false, load: true, rn: 11, rd: 1, sh: 1, imm: 2), // post-index ldrh
        _trH(14, pre: true, up: true, wb: true, load: true, rn: 11, rd: 2, sh: 1, rm: 0), // register offset form
        _halt,
      ];
      _compareArm(program, cycles: true);
    });

    test('swap, word and byte', () {
      _compareArm([
        _tr(14, pre: true, up: true, byte: false, wb: false, load: true, rn: 10, rd: 0, offset: 8),
        _swap(14, false, 11, 1, 0), // swp r1, r0, [r11]
        _swap(14, true, 11, 2, 0), // swpb r2, r0, [r11]
        _add(3, 11, 2),
        _swap(14, false, 3, 4, 1), // swp at an unaligned address
        _halt,
      ], cycles: true);
    });

    test('block transfers in every mode, with writeback', () {
      final program = <int>[
        _mov(0, 0x110), _mov(1, 0x220), _mov(2, 0x330), _mov(3, 0x440), // 0-3
        _add(12, 11, 0x200), // 4
        _block(14, pre: false, up: true, wb: true, load: false, rn: 12, regs: [0, 1, 2, 3]), // 5: stmia r12!
        _mov(0, 0), _mov(1, 0), _mov(2, 0), _mov(3, 0), // 6-9
        _block(14, pre: true, up: false, wb: true, load: true, rn: 12, regs: [0, 1, 2, 3]), // 10: ldmdb r12!
        _add(12, 11, 0x280), // 11
        _block(14, pre: true, up: false, wb: true, load: false, rn: 12, regs: [3, 2]), // 12: stmdb r12!
        _block(14, pre: false, up: true, wb: false, load: true, rn: 12, regs: [4, 5]), // 13: ldmia r12 (no writeback)
        _block(14, pre: false, up: false, wb: true, load: false, rn: 12, regs: [0, 1, 2, 3, 12]), // 14: stmda r12!, base last in list
        _block(14, pre: true, up: true, wb: true, load: true, rn: 12, regs: [6, 7, 12]), // 15: ldmib r12!, base in list
        _halt, // 16
      ];
      _compareArm(program, cycles: true);
    });

    test('block load to PC and stack push/pop shapes', () {
      final program = <int>[
        _mov(0, 0x55), // 0
        _block(14, pre: true, up: false, wb: true, load: false, rn: 13, regs: [0, 14]), // 1: stmdb sp!, {r0, lr}
        _mov(0, 0), // 2
        _block(14, pre: false, up: true, wb: true, load: true, rn: 13, regs: [1, 14]), // 3: ldmia sp!, {r1, lr}
        _add(12, 11, 0x300), // 4
        _block(14, pre: false, up: true, wb: false, load: true, rn: 12, regs: [15]), // 5: ldmia r12, {pc}
        _mov(0, 0xee000000), // 6 (skipped)
        _mov(0, 0xee000000), // 7 (skipped)
        _add(2, 1, 1), // 8: landing pad
        _halt, // 9
      ];
      // [r12] must hold the address of index 8.
      final data = _seedData();
      data.buffer.asByteData().setUint32(0x300, _code + 4 * 8, Endian.little);
      _compareArm(program, data: data, cycles: true);
    });

    test('branches, links and loops', () {
      final program = <int>[
        _mov(0, 0), // 0
        _mov(9, 5), // 1: loop counter
        _add(0, 0, 3), // 2: loop
        _sub(9, 9, 1, s: true), // 3
        _b(1, 4, 2), // 4: bne loop
        _b(14, 5, 8, link: true), // 5: bl sub
        _add(0, 0, 0x10), // 6: after the call
        _b(14, 7, 10), // 7: b halt
        _add(0, 0, 7), // 8: sub
        _movR(15, 14), // 9: mov pc, lr
        _halt, // 10
      ];
      _compareArm(program);
    });

    test('PSR transfers and mode switches stay in sync', () {
      // MRS/MSR run in the interpreter on both machines; the compiled
      // blocks around them must observe the banked registers and the
      // flag state the interpreter leaves behind.
      final program = <int>[
        _mrs(0), // mrs r0, cpsr
        _mov(1, 0x92), // IRQ mode, IRQ/FIQ disabled
        _msr(1, 1), // msr cpsr_c, r1
        _mov(13, 0x3000), // sp_irq (low bits; high bits set below)
        _dpI(14, 12, false, 13, 13, _imm(0x03000000)), // orr sp, sp, #0x03000000
        _mrs(2),
        _mov(3, 0x9f), // system mode, interrupts disabled
        _msr(1, 3),
        _dpI(14, 4, true, 13, 4, _imm(1)), // adds r4, sp, #1 (flags from the interpreter's cpsr)
        _mrs(5),
        // A test opcode with S clear is a PSR transfer in this
        // decoder: this "teq" writes the CPSR flag byte (Z set) and
        // runs in the interpreter on both machines.
        _dpI(14, 9, false, 8, 15, _imm(0x40000000)),
        _dpI(0, 13, false, 0, 6, _imm(0x33)), // moveq r6, #0x33
        _dpI(1, 13, false, 0, 7, _imm(0x44)), // movne r7, #0x44 (skipped)
        _halt,
      ];
      _compareArm(program);
    });

    test('self-modifying code in IWRAM', () {
      // The instruction in the patch slot runs once in its old form
      // (its block compiles), the program then overwrites it with a
      // compiled store, and the second pass must run the new form:
      // the store releases the code page, and the block guards would
      // catch the change in any case.
      final program = <int>[
        _tr(14, pre: true, up: true, byte: false, wb: false, load: true, rn: 10, rd: 1, offset: 0x40), // 0: ldr r1, patch word
        _tr(14, pre: true, up: true, byte: false, wb: false, load: true, rn: 10, rd: 2, offset: 0x44), // 1: ldr r2, patch address
        _mov(3, 0), // 2: pass counter
        _add(3, 3, 1), // 3: loop head
        _mov(0, 2), // 4: patch slot
        _dpI(14, 10, true, 3, 0, _imm(2)), // 5: cmp r3, #2
        _b(0, 6, 9), // 6: beq halt
        _tr(14, pre: true, up: true, byte: false, wb: false, load: false, rn: 2, rd: 1, offset: 0), // 7: str r1, [r2]
        _b(14, 8, 3), // 8: b loop head
        _halt, // 9
      ];
      final data = _seedData();
      final patch = _dpI(14, 13, false, 0, 0, _imm(0x77)); // mov r0, #0x77
      data.buffer.asByteData().setUint32(0x40, patch, Endian.little);
      data.buffer.asByteData().setUint32(0x44, _code + 4 * 4, Endian.little);
      _compareArm(program, data: data);
    });
  });

  group('directed Thumb programs', () {
    test('immediate operations and flags', () {
      _compareThumb([
        _tImm(0, 0, 0xff), // movs r0, #0xff
        _tImm(2, 0, 1), // adds r0, #1
        _tImm(1, 0, 0x00), // cmp r0, #0
        _tImm(3, 0, 0xff), // subs r0, #0xff
        _tImm(0, 1, 0x80), // movs r1, #0x80
        _tShift(0, 24, 1, 1), // lsls r1, r1, #24
        _tShift(1, 31, 1, 2), // lsrs r2, r1, #31
        _tShift(2, 31, 1, 3), // asrs r3, r1, #31
        _tShift(1, 0, 1, 4), // lsrs r4, r1, #32 (encoded 0)
        _tShift(2, 0, 1, 5), // asrs r5, r1, #32 (encoded 0)
        _tAddSub(3, 0, 6, sub: false, imm: true), // adds r6, r0, #3
        _tAddSub(1, 6, 7, sub: true), // subs r7, r6, r1
        _tHalt,
      ], cycles: true);
    });

    test('ALU operations, including register shifts and multiply', () {
      _compareThumb([
        _tImm(0, 0, 200),
        _tImm(0, 1, 7),
        _tAlu(0x2, 1, 0), // lsls r0, r1 (by 200 & 0xff)
        _tImm(0, 2, 33),
        _tAlu(0x3, 2, 0), // lsrs r0, r2 (by 33)
        _tAlu(0x4, 2, 0), // asrs r0, r2
        _tAlu(0x7, 2, 0), // rors r0, r2
        _tImm(0, 3, 0),
        _tAlu(0x5, 1, 3), // adcs r3, r1
        _tAlu(0x6, 1, 3), // sbcs r3, r1
        _tAlu(0x9, 0, 3), // negs r3, r0
        _tAlu(0xa, 1, 3), // cmp r3, r1
        _tAlu(0xb, 1, 3), // cmn r3, r1
        _tAlu(0x8, 1, 3), // tst r3, r1
        _tAlu(0x0, 1, 3), // ands r3, r1
        _tAlu(0x1, 1, 3), // eors r3, r1
        _tAlu(0xc, 1, 3), // orrs r3, r1
        _tAlu(0xe, 1, 3), // bics r3, r1
        _tAlu(0xf, 1, 3), // mvns r3, r1
        _tAlu(0xd, 1, 3), // muls r3, r1
        _tHalt,
      ]);
    });

    test('loads and stores in every format', () {
      // r4 = IWRAM data (from r10), r5 = EWRAM data (from r11).
      _compareThumb([
        _tHi(2, 10, 4), // mov r4, r10
        _tHi(2, 11, 5), // mov r5, r11
        _tLdStI(0, 4, 0, load: true, byte: false), // ldr r0, [r4]
        _tLdStI(3, 4, 1, load: true, byte: true), // ldrb r1, [r4, #3]
        _tLdStI(1, 5, 0, load: false, byte: false), // str r0, [r5, #4]
        _tLdStH(5, 4, 2, load: true), // ldrh r2, [r4, #10]
        _tLdStH(1, 5, 2, load: false), // strh r2, [r5, #2]
        _tImm(0, 6, 0x21),
        _tLdStR(6, 4, 3, load: true, byte: false), // ldr r3, [r4, r6] (odd: rotates)
        _tLdStR(6, 5, 3, load: false, byte: true), // strb r3, [r5, r6]
        _tLdStS(6, 4, 0, h: false, s: false), // strh r0, [r4, r6]
        _tLdStS(6, 4, 1, h: true, s: false), // ldrh r1, [r4, r6] (odd: rotates)
        _tLdStS(6, 4, 2, h: false, s: true), // ldrsb r2, [r4, r6]
        _tLdStS(6, 4, 3, h: true, s: true), // ldrsh r3, [r4, r6] (odd: byte)
        _tLdStSp(7, 0, load: false), // str r7, [sp]
        _tLdStSp(7, 0, load: true), // ldr r7, [sp]
        _tAddr(0, 16), // add r0, pc, #64
        _tAddr(1, 8, sp: true), // add r1, sp, #32
        _tHalt,
      ], cycles: true);
    });

    test('PC-relative literal load', () {
      // The literal word sits in the middle of the program, skipped
      // by a branch; the load's base is the aligned PC.
      _compareThumb([
        _tLdrPc(0, 1), // 0: ldr r0, [pc, #4] -> the literal at index 4
        _tB(1, 6), // 1: b 6
        0x0000, // 2: filler
        0x0000, // 3: filler
        0x1234, // 4: literal low half
        0xbeef, // 5: literal high half (0xbeef1234)
        _tImm(2, 0, 1), // 6: adds r0, #1
        _tHalt, // 7
      ], cycles: true);
    });

    test('push, pop and stack-relative work', () {
      _compareThumb([
        _tImm(0, 0, 0x11),
        _tImm(0, 1, 0x22),
        _tImm(0, 2, 0x33),
        _tPushPop([0, 1, 2], load: false, extra: true), // push {r0-r2, lr}
        _tImm(0, 0, 0),
        _tImm(0, 1, 0),
        _tImm(0, 2, 0),
        _tLdStSp(2, 3, load: true), // ldr r3, [sp, #8]
        _tPushPop([4, 5, 6], load: true, extra: false), // pop {r4-r6}
        _tAddSp(3, sub: true), // add sp, #-12 (undo the pop's balance for the check below)
        _tAddSp(3), // add sp, #12
        _tHalt,
      ], cycles: true);
    });

    test('block load/store with base writeback', () {
      _compareThumb([
        _tHi(2, 10, 4), // mov r4, r10
        _tImm(0, 0, 0x51),
        _tImm(0, 1, 0x52),
        _tImm(0, 2, 0x53),
        _tBlock(4, [0, 1, 2], load: false), // stmia r4!, {r0-r2}
        _tImm(0, 0, 0),
        _tImm(0, 1, 0),
        _tImm(0, 2, 0),
        _tHi(2, 10, 4), // mov r4, r10 (reload base)
        _tBlock(4, [0, 1, 2], load: true), // ldmia r4!, {r0-r2}
        _tBlock(4, [0, 4], load: false), // stmia r4!, {r0, r4}: base not first, stores the writeback value
        _tBlock(4, [5, 4], load: true), // ldmia r4!, {r4, r5}: base in list, writeback skipped
        _tHalt,
      ], cycles: true);
    });

    test('branches, conditionals and BL subroutines', () {
      final bl = _tBl(7, 10);
      final program = <int>[
        _tImm(0, 7, 3), // 0: movs r7, #3 (loop counter)
        _tImm(2, 0, 2), // 1: loop: adds r0, #2
        _tImm(3, 7, 1), // 2: subs r7, #1
        _tBcond(1, 3, 1), // 3: bne loop
        _tImm(1, 0, 5), // 4: cmp r0, #5 (6 vs 5: carry set)
        _tBcond(2, 5, 7), // 5: bcs 7 (skips the next)
        _tImm(0, 1, 0xee), // 6: (skipped)
        bl >> 16, // 7: bl sub (first half)
        bl & 0xffff, // 8: bl sub (second half)
        _tB(9, 12), // 9: b halt
        _tImm(2, 1, 0x10), // 10: sub: adds r1, #0x10
        _tHi(2, 14, 15), // 11: mov pc, lr
        _tHalt, // 12
      ];
      _compareThumb(program);
    });

    test('pop {pc} returns from a BL subroutine', () {
      // The stacked word is a Thumb return address taken from data;
      // the subroutine returns through lr, and the caller's pop {pc}
      // lands on the halt.
      final bl = _tBl(3, 7);
      final program = <int>[
        _tHi(2, 10, 4), // 0: mov r4, r10
        _tLdStI(0, 4, 0, load: true, byte: false), // 1: ldr r0, [r4] (return address from data)
        _tPushPop([0], load: false), // 2: push {r0}
        bl >> 16, // 3: bl sub
        bl & 0xffff, // 4
        _tPushPop([], load: true, extra: true), // 5: pop {pc}
        _tImm(0, 1, 0xee), // 6: (skipped when the pop jumps)
        _tImm(2, 2, 9), // 7: sub: adds r2, #9
        _tHi(2, 14, 15), // 8: mov pc, lr
        _tHalt, // 9: halt (the pop target)
      ];
      final data = _seedData();
      data.buffer.asByteData().setUint32(0, _code + 2 * 9 + 1, Endian.little);
      _compareThumb(program, data: data);
    });

    test('BX switches between Thumb and ARM subroutines', () {
      // Thumb code loads an ARM subroutine address and a Thumb
      // return address from data, links lr by hand and BXes over;
      // the ARM side returns with its own BX. BX runs in the
      // interpreter on both machines; the compiled blocks on either
      // side must resume in the right state.
      final thumb = <int>[
        _tHi(2, 10, 4), // 0: mov r4, r10
        _tLdStI(0, 4, 0, load: true, byte: false), // 1: ldr r0, [r4] (subroutine)
        _tLdStI(1, 4, 1, load: true, byte: false), // 2: ldr r1, [r4, #4] (return address)
        _tHi(2, 1, 14), // 3: mov lr, r1
        _tBx(0), // 4: bx r0
        _tImm(2, 1, 0x10), // 5: adds r1, #0x10 (after the return)
        _tHalt, // 6
      ];
      final armSub = <int>[
        _add(2, 2, 7), // add r2, r2, #7
        (14 << 28) | 0x012fff1e, // bx lr
      ];
      final data = _seedData();
      data.buffer.asByteData().setUint32(0, _code + 0x100, Endian.little);
      data.buffer.asByteData().setUint32(4, _code + 2 * 5 + 1, Endian.little);
      final end = _code + 2 * 6;
      void setup(_Machine m) {
        m.loadThumb(thumb, data);
        for (final (i, w) in armSub.indexed) {
          m.bus.write32(_code + 0x100 + 4 * i, w);
        }
      }

      final ref = _Machine.interpreter();
      setup(ref);
      ref.runTo(end);
      for (final jit in _jits()) {
        final machine = _Machine.jit(jit);
        setup(machine);
        machine.runTo(end);
        _expectSame(ref, machine, cycles: false);
        jit.dispose();
      }
    });

    test('self-modifying Thumb code', () {
      // Same shape as the ARM test: the slot runs, is patched by a
      // compiled store, and must run in its new form on the second
      // pass. Guards cover the aligned word holding the halfword.
      final program = <int>[
        _tHi(2, 10, 4), // 0: mov r4, r10
        _tLdStI(0, 4, 0, load: true, byte: false), // 1: ldr r0, [r4] (patch halfword + filler)
        _tLdStI(1, 4, 1, load: true, byte: false), // 2: ldr r1, [r4, #4] (slot address)
        _tImm(0, 3, 0), // 3: movs r3, #0
        _tImm(2, 3, 1), // 4: loop: adds r3, #1
        _tImm(0, 2, 2), // 5: patch slot: movs r2, #2
        _tImm(1, 3, 2), // 6: cmp r3, #2
        _tBcond(0, 7, 10), // 7: beq halt
        _tLdStH(0, 1, 0, load: false), // 8: strh r0, [r1]
        _tB(9, 4), // 9: b loop
        _tHalt, // 10
      ];
      final data = _seedData();
      final patch = _tImm(0, 2, 0x77); // movs r2, #0x77
      data.buffer.asByteData().setUint32(0, patch, Endian.little);
      data.buffer.asByteData().setUint32(4, _code + 2 * 5, Endian.little);
      _compareThumb(program, data: data);
    });
  });
}
