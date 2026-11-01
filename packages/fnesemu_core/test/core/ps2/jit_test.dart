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

(R5900, Ps2Bus) _load(Ps2Jit? jit) {
  final bus = Ps2Bus(ram: jit?.ram);
  final cpu = R5900(bus, gpr: jit?.gpr);
  jit?.attach(cpu);
  final words = _words();
  for (var i = 0; i < words.length; i++) {
    bus.write32(_base + i * 4, words[i]);
  }
  bus.write64(_data, 0x0123456789abcdef);
  bus.write64(_data + 8, -0x0123456789abcdf0);
  cpu.jumpTo(_base);
  return (cpu, bus);
}

void _compare(Ps2Jit? jit, String name) {
  final (expected, expectedBus) = _load(null);
  while (expected.clocks < 400) {
    expected.step();
  }
  final (cpu, bus) = _load(jit);
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
  for (var a = _data; a < _data + 48; a += 8) {
    expect(bus.read64(a), expectedBus.read64(a), reason: '$name 0x$a');
  }
}

void main() {
  test('compiled code matches the interpreter', () {
    final jit = Ps2Jit.create(compileThreshold: 1);
    if (jit == null) return; // no little-endian host
    addTearDown(jit.dispose);
    _compare(jit, 'native');
  });

  test('the reference IR matches the interpreter', () {
    final jit = Ps2Jit.create(native: false, compileThreshold: 1)!;
    addTearDown(jit.dispose);
    _compare(jit, 'reference');
  });

  for (final native in [false, true]) {
    test('${native ? 'native' : 'reference'} EE DIV/DIVU and MMI DIV1/DIVU1 preserve HI/LO', () {
      final jit = Ps2Jit.create(native: native, compileThreshold: 1);
      if (jit == null) {
        markTestSkipped('Native JIT unsupported on this host');
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

  test('unmapped LW skips repeated empty native entries but still reads IO',
      () {
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

  test('reference IR preserves IO reads and a later RAM load', () {
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

  test('rewritten code invalidates the unmapped LW fast path', () {
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

  test('an interrupt is taken before a cached unmapped load', () {
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

  test('a cached unmapped load still executes as a branch delay slot', () {
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

  test('a remapped TLB address uses the interpreter and the new mapping', () {
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

  test('a misaligned cached load still raises an address exception', () {
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

  test('reset clears the cached unmapped load', () {
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

  test('an overflowing ADD leaves to the interpreter for the exception', () {
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
}
