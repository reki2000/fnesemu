import 'dart:async';
import 'package:fnesemu_core/src/core/ps2/bus.dart';
import 'package:fnesemu_core/src/core/ps2/jit/ps2_jit.dart';
import 'package:fnesemu_core/src/core/ps2/r5900/r5900.dart';
import 'package:test/test.dart';

int _r(int fn, {int rs = 0, int rt = 0, int rd = 0, int sa = 0}) =>
    rs << 21 | rt << 16 | rd << 11 | sa << 6 | fn;
int _i(int op, int rs, int rt, int imm) =>
    op << 26 | rs << 21 | rt << 16 | (imm & 0xffff);

const _base = 0x100000, _data = 0x200000;

class _CountingIo implements IoPort {
  int reads = 0;

  @override
  bool handles(int address) => address == 0x1000f000;

  @override
  int read(int address, int size) {
    reads++;
    return 0x81234567;
  }

  @override
  bool write(int address, int size, int value) => false;
}

/// A program that touches the translated instructions and ends in a loop
/// on itself. r1 holds the data address.
final _program = [
  _i(15, 0, 1, _data >> 16), // lui r1, data
  _i(9, 0, 2, -5), // addiu r2, zero, -5
  _i(13, 0, 3, 0x8001), // ori r3, zero, 0x8001
  _r(0, rt: 3, rd: 4, sa: 16), // sll r4, r3, 16
  _r(3, rt: 4, rd: 5, sa: 4), // sra r5, r4, 4
  _r(2, rt: 4, rd: 6, sa: 4), // srl r6, r4, 4
  _r(60, rt: 2, rd: 7, sa: 3), // dsll32 r7, r2, 3
  _r(62, rt: 7, rd: 8, sa: 1), // dsrl32 r8, r7, 1
  _r(63, rt: 7, rd: 9, sa: 0), // dsra32 r9, r7, 0
  _r(45, rs: 7, rt: 3, rd: 10), // daddu r10, r7, r3
  _r(47, rs: 3, rt: 7, rd: 11), // dsubu r11, r3, r7
  _r(42, rs: 2, rt: 3, rd: 12), // slt r12, r2, r3
  _r(43, rs: 2, rt: 3, rd: 13), // sltu r13, r2, r3
  _i(10, 2, 14, -4), // slti r14, r2, -4
  _i(11, 3, 15, -1), // sltiu r15, r3, -1
  _r(10, rs: 3, rt: 0, rd: 16), // movz r16, r3, zero
  _r(11, rs: 3, rt: 0, rd: 17), // movn r17, r3, zero
  _r(20, rs: 2, rt: 3, rd: 18), // dsllv r18, r3, r2
  _r(39, rs: 2, rt: 3, rd: 19), // nor r19, r2, r3
  _i(43, 1, 4, 0), // sw r4, 0(r1)
  _i(41, 1, 3, 6), // sh r3, 6(r1)
  _i(40, 1, 2, 9), // sb r2, 9(r1)
  _i(63, 1, 7, 16), // sd r7, 16(r1)
  _i(32, 1, 20, 9), // lb r20, 9(r1)
  _i(36, 1, 21, 9), // lbu r21, 9(r1)
  _i(33, 1, 22, 6), // lh r22, 6(r1)
  _i(37, 1, 23, 6), // lhu r23, 6(r1)
  _i(35, 1, 24, 0), // lw r24, 0(r1)
  _i(39, 1, 25, 0), // lwu r25, 0(r1)
  _i(55, 1, 26, 16), // ld r26, 16(r1)
  _i(30, 1, 27, 5), // lq r27, 5(r1): aligned down to 0
  _i(31, 1, 27, 32), // sq r27, 32(r1)
  _i(9, 0, 28, 3), // addiu r28, zero, 3
  // loop: r29 += r28 three times
  _r(33, rs: 29, rt: 28, rd: 29), // addu r29, r29, r28
  _i(9, 28, 28, -1), // addiu r28, r28, -1
  _i(5, 28, 0, -3), // bne r28, zero, loop
  _r(0), // nop
  _i(20, 0, 2, 2), // beql zero, r2, +2: not taken, skips the slot
  _i(9, 0, 30, 1), // addiu r30, zero, 1 (annulled)
  _i(3, 0, 0, 0), // jal target, patched below
  _i(9, 0, 30, 7), // addiu r30, zero, 7 (delay slot)
  _i(4, 0, 0, -1), // end: beq zero, zero, end
  _r(0), // nop
];

final _jalAt = _program.indexOf(_i(3, 0, 0, 0));

List<int> _words() {
  final words = List.of(_program);
  // jal to the end loop
  final end = _base + (_program.length - 2) * 4;
  words[_jalAt] = 3 << 26 | ((end >> 2) & 0x3ffffff);
  return words;
}

(R5900, Ps2Bus) _load(Ps2Jit? jit,
    [List<int>? words, List<int>? data]) {
  final bus = Ps2Bus(ram: jit?.ram);
  final cpu = R5900(bus, gpr: jit?.gpr, fpr: jit?.fpr);
  jit?.attach(cpu);
  final program = words ?? _words();
  for (var i = 0; i < program.length; i++) {
    bus.write32(_base + i * 4, program[i]);
  }
  if (data == null) {
    bus.write64(_data, 0x0123456789abcdef);
    bus.write64(_data + 8, -0x0123456789abcdf0);
  } else {
    for (var i = 0; i < data.length; i++) {
      bus.write32(_data + i * 4, data[i]);
    }
  }
  cpu.jumpTo(_base);
  return (cpu, bus);
}

void _compare(Ps2Jit? jit, String name,
    [List<int>? words, List<int>? data]) {
  final (expected, expectedBus) = _load(null, words, data);
  while (expected.clocks < 400) {
    expected.step();
  }
  final (cpu, bus) = _load(jit, words, data);
  var compiled = 0;
  for (var guard = 0; cpu.clocks < 400 && guard < 10000; guard++) {
    final before = cpu.clocks;
    if (jit != null && jit.run(400 - cpu.clocks)) {
      compiled += cpu.clocks - before;
    } else {
      cpu.step();
    }
  }
  expect(compiled, greaterThan(0), reason: '$name ran no compiled code');
  expect(cpu.pc, expected.pc, reason: name);
  for (var r = 0; r < 64; r++) {
    expect(cpu.gpr[r], expected.gpr[r], reason: '$name gpr[$r]');
  }
  for (var r = 0; r < 32; r++) {
    expect(cpu.fpr[r], expected.fpr[r], reason: '$name fpr[$r]');
  }
  expect(cpu.facc, expected.facc, reason: '$name facc');
  expect(cpu.fcr31, expected.fcr31, reason: '$name fcr31');
  for (var a = _data; a < _data + 48; a += 8) {
    expect(bus.read64(a), expectedBus.read64(a), reason: '$name 0x$a');
  }
}

int _cop1(int fmt, {int ft = 0, int fs = 0, int fd = 0, int fn = 0}) =>
    17 << 26 | fmt << 21 | ft << 16 | fs << 11 | fd << 6 | fn;
int _s(int fn, {int ft = 0, int fs = 0, int fd = 0}) =>
    _cop1(16, ft: ft, fs: fs, fd: fd, fn: fn);

final _cop1Data = [
  0x3fc00000, // 1.5
  0x40100000, // 2.25
  0x7f800000, // exponent field 255: 2^128
  0x00000001, // a denormal image
  0x00800000, // 2^-126
  0xc0000000, // -2.0
  0x4f000000, // 2^31
  0x00000000, // 0
];

/// A COP1 program: every translated form, the flag paths (divide by zero,
/// invalid, overflow, underflow), the accumulator forms, a load that
/// leaves the compiled memory mapping between two FPU operations (the
/// side exit snapshot path), and an FPU operation in a branch delay slot.
final _cop1Program = [
  _i(15, 0, 1, _data >> 16), // lui r1, data
  _i(49, 1, 1, 0), // lwc1 f1, 0(r1)
  _i(49, 1, 2, 4), // lwc1 f2, 4(r1)
  _i(49, 1, 4, 8), // lwc1 f4, 8(r1)
  _i(49, 1, 5, 12), // lwc1 f5, 12(r1)
  _i(49, 1, 6, 16), // lwc1 f6, 16(r1)
  _i(49, 1, 7, 20), // lwc1 f7, 20(r1)
  _i(49, 1, 8, 24), // lwc1 f8, 24(r1)
  _i(49, 1, 0, 28), // lwc1 f0, 28(r1)
  _s(0x00, fs: 1, ft: 2, fd: 3), // add.s f3, f1, f2
  _s(0x01, fs: 1, ft: 2, fd: 10), // sub.s f10, f1, f2
  _s(0x02, fs: 1, ft: 2, fd: 11), // mul.s f11, f1, f2
  _s(0x03, fs: 2, ft: 1, fd: 12), // div.s f12, f2, f1
  _s(0x03, fs: 1, ft: 0, fd: 13), // div.s f13, f1, f0
  _s(0x03, fs: 0, ft: 0, fd: 14), // div.s f14, f0, f0
  _s(0x04, ft: 2, fd: 15), // sqrt.s f15, f2
  _s(0x04, ft: 7, fd: 16), // sqrt.s f16, f7
  _s(0x16, fs: 1, ft: 2, fd: 17), // rsqrt.s f17, f1, f2
  _s(0x05, fs: 7, fd: 18), // abs.s f18, f7
  _s(0x07, fs: 1, fd: 19), // neg.s f19, f1
  _s(0x06, fs: 2, fd: 20), // mov.s f20, f2
  _s(0x00, fs: 4, ft: 4, fd: 21), // add.s f21, f4, f4
  _s(0x00, fs: 5, ft: 1, fd: 22), // add.s f22, f5, f1
  _s(0x02, fs: 6, ft: 6, fd: 23), // mul.s f23, f6, f6
  _s(0x18, fs: 1, ft: 2), // adda.s f1, f2
  _s(0x1c, fs: 1, ft: 2, fd: 24), // madd.s f24, f1, f2
  _s(0x1d, fs: 1, ft: 2, fd: 25), // msub.s f25, f1, f2
  _s(0x1e, fs: 1, ft: 2), // madda.s f1, f2
  _s(0x1f, fs: 1, ft: 2), // msuba.s f1, f2
  _s(0x24, fs: 2, fd: 26), // cvt.w.s f26, f2
  _s(0x24, fs: 8, fd: 27), // cvt.w.s f27, f8
  _s(0x28, fs: 1, ft: 7, fd: 28), // max.s f28, f1, f7
  _s(0x29, fs: 1, ft: 7, fd: 29), // min.s f29, f1, f7
  _s(0x32, fs: 1, ft: 2), // c.eq.s f1, f2
  _s(0x34, fs: 1, ft: 2), // c.lt.s f1, f2
  _cop1(2, ft: 5, fs: 31), // cfc1 r5, 31
  _s(0x30), // c.f.s
  _cop1(2, ft: 6, fs: 31), // cfc1 r6, 31
  _cop1(0, ft: 7, fs: 3), // mfc1 r7, f3
  _cop1(4, ft: 7, fs: 30), // mtc1 r7, f30
  _i(57, 1, 3, 32), // swc1 f3, 32(r1)
  _i(57, 1, 13, 36), // swc1 f13, 36(r1)
  _i(57, 1, 24, 40), // swc1 f24, 40(r1)
  _i(43, 1, 5, 44), // sw r5, 44(r1)
  _s(0x02, fs: 1, ft: 2, fd: 9), // mul.s f9, f1, f2
  _i(15, 0, 8, 0x1f80), // lui r8, 0x1f80
  _i(35, 8, 10, 0), // lw r10, 0(r8): the scratchpad, outside the mapping
  _s(0x00, fs: 9, ft: 1, fd: 9), // add.s f9, f9, f1
  _i(13, 0, 11, 0xffff), // ori r11, zero, 0xffff
  _cop1(6, ft: 11, fs: 31), // ctc1 r11, 31
  _s(0x00, fs: 1, ft: 2, fd: 31), // add.s f31, f1, f2
  _cop1(2, ft: 12, fs: 31), // cfc1 r12, 31
  _i(4, 0, 0, 2), // beq zero, zero, +2
  _s(0x00, fs: 1, ft: 2, fd: 31), // add.s f31, f1, f2 (delay slot)
  _i(9, 0, 30, 1), // addiu r30, zero, 1 (skipped)
  _i(4, 0, 0, -1), // end: beq zero, zero, end
  _r(0), // nop
];

class _CaseSkip implements Exception {
  const _CaseSkip();
}

void main() {
  // Aggregated cases: the per-case tests of this file are collected
  // in this table and executed by the aggregated test(s) at the end of
  // main; every case name stays visible here and in the run output.
  final aggCases = <(String, FutureOr<void> Function())>[];
  final aggTeardowns = <void Function()>[];
  void addTearDown(void Function() teardown) => aggTeardowns.add(teardown);
  void aggCase(String name, FutureOr<void> Function() body) =>
      aggCases.add((name, body));
  void aggSkipCase(String reason) => throw const _CaseSkip();
  Future<void> runAggCases(
      Iterable<(String, FutureOr<void> Function())> cases) async {
    for (final (name, body) in cases) {
      print('case: $name');
      try {
        await body();
      } on _CaseSkip {
        print('skipped: $name');
      } finally {
        for (final teardown in aggTeardowns) {
          teardown();
        }
        aggTeardowns.clear();
      }
    }
  }

  aggCase('compiled code matches the interpreter', () {
    final jit = Ps2Jit.create(compileThreshold: 1);
    if (jit == null) return; // no little-endian host
    addTearDown(jit.dispose);
    _compare(jit, 'native');
  });

  aggCase('the reference IR matches the interpreter', () {
    final jit = Ps2Jit.create(native: false, compileThreshold: 1)!;
    addTearDown(jit.dispose);
    _compare(jit, 'reference');
  });

  aggCase('compiled COP1 matches the interpreter', () {
    final jit = Ps2Jit.create(compileThreshold: 1);
    if (jit == null) return; // no little-endian host
    addTearDown(jit.dispose);
    _compare(jit, 'native cop1', _cop1Program, _cop1Data);
  });

  aggCase('reference IR COP1 matches the interpreter', () {
    final jit = Ps2Jit.create(native: false, compileThreshold: 1)!;
    addTearDown(jit.dispose);
    _compare(jit, 'reference cop1', _cop1Program, _cop1Data);
  });


  for (final native in [false, true]) {
    aggCase('${native ? 'native' : 'reference'} EE DIV/DIVU and MMI DIV1/DIVU1 preserve HI/LO', () {
      final jit = Ps2Jit.create(native: native, compileThreshold: 1);
      if (jit == null) {
        aggSkipCase('Native JIT unsupported on this host');
        return;
      }
      addTearDown(jit.dispose);
      final (expected, expectedBus) = _load(null);
      final (actual, actualBus) = _load(jit);

      // Include zero divisors, signed MIN/-1, unsigned word operands,
      // negative operands, and upper halves of 64-bit GPR values.
      final pairs = [
        (0, 0),
        (1, 0),
        (-1, 0),
        (-7, 3),
        (7, -3),
        (-0x80000000, -1),
        (0x80000000, 2),
        (0xffffffff, 3),
        (0x7fffffff00000009, -0x100000001),
        (-0x8000000000000000, 0),
      ];
      for (final signed in [true, false]) {
        for (final (x, y) in pairs) {
          const mmi = 28 << 26;
          final instructions = [
            _r(17, rs: 1), // MTHI
            _r(19, rs: 2), // MTLO
            mmi | _r(0x11, rs: 2), // MTHI1
            mmi | _r(0x13, rs: 1), // MTLO1
            _r(signed ? 26 : 27, rs: 1, rt: 2), // DIV/DIVU
            _r(18, rd: 3), // MFLO
            _r(16, rd: 4), // MFHI
            mmi | _r(signed ? 0x1a : 0x1b, rs: 1, rt: 2),
            mmi | _r(0x12, rd: 5), // MFLO1
            mmi | _r(0x10, rd: 6), // MFHI1
            _r(17, rs: 3), // MTHI (tests writeback across JIT boundaries)
            _r(19, rs: 4), // MTLO
            mmi | _r(0x11, rs: 5),
            mmi | _r(0x13, rs: 6),
          ];
          jit.reset();
          for (final (cpu, bus) in [(expected, expectedBus), (actual, actualBus)]) {
            cpu.reset();
            for (final (index, instruction) in instructions.indexed) {
              bus.write32(_base + index * 4, instruction);
            }
            // End translation before the next fixture instruction so that
            // JIT execution cannot run past the comparison boundary.
            bus.write32(_base + instructions.length * 4, _r(12)); // SYSCALL
            cpu.setReg(1, x);
            cpu.setReg(2, y);
            cpu.jumpTo(_base);
          }
          for (var i = 0; i < instructions.length; i++) {
            expected.step();
          }
          var compiled = 0;
          for (var guard = 0; actual.clocks < instructions.length && guard < 100; guard++) {
            final before = actual.clocks;
            if (jit.run(instructions.length - actual.clocks)) {
              compiled += actual.clocks - before;
            } else {
              actual.step();
            }
          }
          expect(actual.clocks, instructions.length, reason: '$signed $x / $y');
          for (var i = 0; i < 64; i++) {
            expect(actual.gpr[i], expected.gpr[i],
                reason: 'gpr[$i] signed=$signed $x / $y');
          }
          expect((actual.hi, actual.lo, actual.hi1, actual.lo1),
              (expected.hi, expected.lo, expected.hi1, expected.lo1),
              reason: 'HI/LO signed=$signed $x / $y');
          expect(compiled, greaterThan(0),
              reason: 'DIV instructions were not compiled: $signed $x / $y');
        }
      }
    });
  }

  aggCase('unmapped LW skips repeated empty native entries but still reads IO', () {
    final jit = Ps2Jit.create(compileThreshold: 1);
    if (jit == null) return;
    addTearDown(jit.dispose);
    final io = _CountingIo();
    final bus = Ps2Bus(ram: jit.ram)..io = io;
    final cpu = R5900(bus, gpr: jit.gpr);
    jit.attach(cpu);
    bus.write32(_base, _i(35, 3, 2, -4)); // lw r2, -4(r3)
    cpu.setReg(3, 0xb000f004); // uncached alias of the IO register
    cpu.jumpTo(_base);
    expect(jit.run(1), isFalse);
    final entries = jit.rt.nativeEntries;
    expect(entries, greaterThan(0));
    expect(cpu.step(), isTrue);
    expect(io.reads, 1);
    expect(cpu.reg(2), 0x81234567.toSigned(32));

    cpu.jumpTo(_base);
    expect(jit.run(1), isFalse);
    expect(jit.rt.nativeEntries, entries);
    expect(cpu.step(), isTrue);
    expect(io.reads, 2);
    expect(cpu.reg(2), 0x81234567.toSigned(32));

    // The same load can address RAM without recompiling its instruction.
    bus.write32(_data, 0x76543210);
    cpu.setReg(3, 0x80000000 + _data + 4);
    cpu.jumpTo(_base);
    expect(jit.run(1), isTrue);
    expect(jit.rt.nativeEntries, greaterThan(entries));
    expect(cpu.reg(2), 0x76543210);
  });

  aggCase('reference IR preserves IO reads and a later RAM load', () {
    final jit = Ps2Jit.create(native: false, compileThreshold: 1)!;
    addTearDown(jit.dispose);
    final io = _CountingIo();
    final bus = Ps2Bus(ram: jit.ram)..io = io;
    final cpu = R5900(bus, gpr: jit.gpr);
    jit.attach(cpu);
    bus.write32(_base, _i(35, 3, 2, -4));
    cpu.setReg(3, 0xb000f004);
    for (var i = 0; i < 2; i++) {
      cpu.jumpTo(_base);
      expect(jit.run(1), isFalse);
      expect(cpu.step(), isTrue);
      expect(io.reads, i + 1);
      expect(cpu.reg(2), 0x81234567.toSigned(32));
    }

    bus.write32(_data, 0x76543210);
    cpu.setReg(3, 0x80000000 + _data + 4);
    cpu.jumpTo(_base);
    expect(jit.run(1), isTrue);
    expect(cpu.reg(2), 0x76543210);
  });

  aggCase('rewritten code invalidates the unmapped LW fast path', () {
    final jit = Ps2Jit.create(compileThreshold: 1);
    if (jit == null) return;
    addTearDown(jit.dispose);
    final bus = Ps2Bus(ram: jit.ram)..io = _CountingIo();
    final cpu = R5900(bus, gpr: jit.gpr);
    jit.attach(cpu);
    bus.write32(_base, _i(35, 3, 2, -4));
    cpu.setReg(3, 0xb000f004);
    cpu.jumpTo(_base);
    expect(jit.run(1), isFalse);
    expect(cpu.step(), isTrue);

    final entries = jit.rt.nativeEntries;
    bus.write32(_base, _i(9, 0, 2, 123)); // replace LW with ADDIU
    cpu.jumpTo(_base);
    expect(jit.run(1), isTrue);
    expect(jit.rt.nativeEntries, greaterThan(entries));
    expect(cpu.reg(2), 123);
  });

  aggCase('an interrupt is taken before a cached unmapped load', () {
    final jit = Ps2Jit.create(compileThreshold: 1);
    if (jit == null) return;
    addTearDown(jit.dispose);
    final io = _CountingIo();
    final bus = Ps2Bus(ram: jit.ram)..io = io;
    final cpu = R5900(bus, gpr: jit.gpr);
    jit.attach(cpu);
    bus.write32(_base, _i(35, 3, 2, -4));
    cpu.setReg(3, 0xb000f004);
    cpu.jumpTo(_base);
    expect(jit.run(1), isFalse);
    expect(cpu.step(), isTrue);
    expect(io.reads, 1);

    cpu.jumpTo(_base);
    cpu.cop0[R5900.cop0Status] = (1 << 16) | 1 | R5900.ipIntc;
    cpu.setInterruptLine(R5900.ipIntc, true);
    expect(jit.run(1), isFalse);
    expect(cpu.step(), isTrue);
    expect(cpu.cop0[R5900.cop0Epc], _base);
    expect(cpu.pc, 0x80000204);
    expect(io.reads, 1);
  });

  aggCase('a cached unmapped load still executes as a branch delay slot', () {
    final jit = Ps2Jit.create(compileThreshold: 1);
    if (jit == null) return;
    addTearDown(jit.dispose);
    final io = _CountingIo();
    final bus = Ps2Bus(ram: jit.ram)..io = io;
    final cpu = R5900(bus, gpr: jit.gpr);
    jit.attach(cpu);
    bus.write32(_base, _i(4, 0, 0, 2)); // beq r0, r0, target
    bus.write32(_base + 4, _i(35, 3, 2, -4));
    cpu.setReg(3, 0xb000f004);
    cpu.jumpTo(_base + 4);
    expect(jit.run(1), isFalse);
    expect(cpu.step(), isTrue);

    cpu.jumpTo(_base);
    expect(cpu.step(), isTrue);
    expect(cpu.pc, _base + 4);
    final entries = jit.rt.nativeEntries;
    expect(jit.run(1), isFalse);
    expect(jit.rt.nativeEntries, entries);
    expect(cpu.step(), isTrue);
    expect(cpu.pc, _base + 12);
    expect(io.reads, 2);
  });

  aggCase('a remapped TLB address uses the interpreter and the new mapping', () {
    final jit = Ps2Jit.create(compileThreshold: 1);
    if (jit == null) return;
    addTearDown(jit.dispose);
    final io = _CountingIo();
    final bus = Ps2Bus(ram: jit.ram)..io = io;
    final cpu = R5900(bus, gpr: jit.gpr);
    jit.attach(cpu);
    const code = 0x80000000 + _base;
    bus.write32(code, _i(35, 3, 2, -4));
    cpu.setReg(3, 0xb000f004);
    cpu.jumpTo(code);
    expect(jit.run(1), isFalse);
    expect(cpu.step(), isTrue);
    expect(io.reads, 1);

    bus.write32(_data, 0x76543210);
    // The odd page at 0x1000f000 now maps to main memory.
    cpu.tlb.write(0, 0, 0x1000e000, 1, ((_data >> 12) << 6) | 7);
    expect(cpu.tlb.userIdentity, isFalse);
    cpu.setReg(3, 0x1000f004);
    cpu.jumpTo(code);
    expect(jit.run(1), isFalse);
    expect(cpu.step(), isTrue);
    expect(cpu.reg(2), 0x76543210);
    expect(io.reads, 1);
  });

  aggCase('a misaligned cached load still raises an address exception', () {
    final jit = Ps2Jit.create(compileThreshold: 1);
    if (jit == null) return;
    addTearDown(jit.dispose);
    final io = _CountingIo();
    final bus = Ps2Bus(ram: jit.ram)..io = io;
    final cpu = R5900(bus, gpr: jit.gpr);
    jit.attach(cpu);
    bus.write32(_base, _i(35, 3, 2, -4));
    cpu.setReg(3, 0xb000f004);
    cpu.jumpTo(_base);
    expect(jit.run(1), isFalse);
    expect(cpu.step(), isTrue);

    cpu.cop0[R5900.cop0Status] = 0;
    cpu.setReg(3, 0xb000f005);
    cpu.jumpTo(_base);
    expect(jit.run(1), isFalse);
    expect(cpu.step(), isTrue);
    expect(cpu.cop0[R5900.cop0BadVAddr], 0xb000f001);
    expect(cpu.cop0[R5900.cop0Epc], _base);
    expect(cpu.pc, 0x80000180);
    expect(io.reads, 1);
  });

  aggCase('reset clears the cached unmapped load', () {
    final jit = Ps2Jit.create(compileThreshold: 1);
    if (jit == null) return;
    addTearDown(jit.dispose);
    final bus = Ps2Bus(ram: jit.ram)..io = _CountingIo();
    final cpu = R5900(bus, gpr: jit.gpr);
    jit.attach(cpu);
    bus.write32(_base, _i(35, 3, 2, -4));
    cpu.setReg(3, 0xb000f004);
    cpu.jumpTo(_base);
    expect(jit.run(1), isFalse);
    expect(cpu.step(), isTrue);

    final entries = jit.rt.nativeEntries;
    jit.reset();
    cpu.jumpTo(_base);
    expect(jit.run(1), isFalse);
    expect(jit.rt.nativeEntries, greaterThan(entries));
  });

  aggCase('an overflowing ADD leaves to the interpreter for the exception', () {
    final jit = Ps2Jit.create(native: false, compileThreshold: 1)!;
    addTearDown(jit.dispose);
    final bus = Ps2Bus(ram: jit.ram);
    final cpu = R5900(bus, gpr: jit.gpr);
    jit.attach(cpu);
    final program = [
      _i(15, 0, 1, 0x7fff), // lui r1, 0x7fff
      _i(9, 0, 3, 1), // addiu r3, zero, 1
      _r(32, rs: 1, rt: 1, rd: 2), // add r2, r1, r1: overflows
      _i(9, 0, 4, 1), // addiu r4, zero, 1
    ];
    for (var i = 0; i < program.length; i++) {
      bus.write32(_base + i * 4, program[i]);
    }
    cpu.jumpTo(_base);
    cpu.cop0[R5900.cop0Status] = 0; // exceptions go to 0x80000180
    expect(jit.run(100), isTrue);
    expect(cpu.pc, _base + 8);
    expect(cpu.reg(3), 1);
    cpu.step();
    expect(cpu.pc, 0x80000180);
    expect(cpu.reg(2), 0);
  });

  const chunkCount = 2;
  final chunkSize = (aggCases.length + chunkCount - 1) ~/ chunkCount;
  for (var part = 0; part < chunkCount; part++) {
    final partCases =
        aggCases.skip(part * chunkSize).take(chunkSize).toList();
    if (partCases.isEmpty) continue;
    test('aggregated cases ${part + 1} of $chunkCount', () async {
      await runAggCases(partCases);
    }, timeout: const Timeout(Duration(minutes: 10)));
  }
}
