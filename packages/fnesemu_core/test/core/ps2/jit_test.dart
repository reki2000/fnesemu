import 'package:fnesemu_core/src/core/ps2/bus.dart';
import 'package:fnesemu_core/src/core/ps2/jit/ps2_jit.dart';
import 'package:fnesemu_core/src/core/ps2/r5900/r5900.dart';
import 'package:test/test.dart';

int _r(int fn, {int rs = 0, int rt = 0, int rd = 0, int sa = 0}) =>
    rs << 21 | rt << 16 | rd << 11 | sa << 6 | fn;
int _i(int op, int rs, int rt, int imm) =>
    op << 26 | rs << 21 | rt << 16 | (imm & 0xffff);

const _base = 0x100000, _data = 0x200000;

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
