import 'dart:async';
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ps2/iop/iop.dart';
import 'package:fnesemu_core/src/core/ps2/iop/iop_memory.dart';
import 'package:fnesemu_core/src/core/ps2/jit/iop_jit.dart';
import 'package:test/test.dart';

int _i(int op, int rs, int rt, int imm) =>
    (op << 26) | (rs << 21) | (rt << 16) | (imm & 0xffff);
int _r(int funct, int rs, int rt, int rd, [int sa = 0]) =>
    (rs << 21) | (rt << 16) | (rd << 11) | (sa << 6) | funct;
int _cop0(int rs, {int rt = 0, int rd = 0}) =>
    16 << 26 | rs << 21 | rt << 16 | rd << 11;

const _base = 0x1000, _data = 0x2000;

/// A program that touches the translated instructions and ends in a
/// loop on itself: loads in and out of their delay slots (a load used
/// by the next instruction, a load overwritten by the next instruction,
/// lwl merging with the in-flight lwr source), the unaligned accesses,
/// divides, MFC0 in its delay, an MTC0 the blocks leave out, a
/// scratchpad access that leaves the compiled RAM mapping, branches of
/// every kind with loads and stores in their delay slots, and a
/// subroutine call and return.
final _program = [
  _i(9, 0, 1, _data), // addiu r1, zero, data
  _i(35, 1, 2, 0), // lw r2, 0(r1)
  _i(35, 1, 3, 4), // lw r3, 4(r1)
  _r(33, 2, 3, 4), // addu r4, r2, r3 (r3 is still its old value)
  _i(43, 1, 4, 8), // sw r4, 8(r1)
  _r(24, 2, 3, 0), // mult r2, r3
  _r(18, 0, 0, 5), // mflo r5
  _r(16, 0, 0, 6), // mfhi r6
  _r(26, 2, 3, 0), // div r2, r3
  _r(18, 0, 0, 7), // mflo r7
  _r(27, 2, 0, 0), // divu r2, zero
  _r(16, 0, 0, 8), // mfhi r8
  _r(19, 2, 0, 0), // mtlo r2
  _r(17, 3, 0, 0), // mthi r3
  _i(34, 1, 9, 1), // lwl r9, 1(r1)
  _i(38, 1, 9, 6), // lwr r9, 6(r1): merges with the lwl in flight
  _i(42, 1, 9, 3), // swl r9, 3(r1)
  _i(46, 1, 9, 5), // swr r9, 5(r1)
  _i(32, 1, 10, 2), // lb r10, 2(r1)
  _i(36, 1, 11, 3), // lbu r11, 3(r1)
  _i(33, 1, 12, 4), // lh r12, 4(r1)
  _i(37, 1, 13, 6), // lhu r13, 6(r1)
  _i(40, 1, 10, 12), // sb r10, 12(r1)
  _i(41, 1, 12, 14), // sh r12, 14(r1)
  _cop0(0, rt: 14, rd: Iop.cop0Cause), // mfc0 r14, Cause
  _r(33, 14, 2, 15), // addu r15, r14, r2 (r14 is still its old value)
  _cop0(4, rt: 2, rd: Iop.cop0Status), // mtc0 r2, Status: left out
  _cop0(0, rt: 16, rd: Iop.cop0Status), // mfc0 r16, Status
  _i(15, 0, 23, 0x1f80), // lui r23, 0x1f80
  _i(35, 23, 24, 0), // lw r24, 0(r23): the scratchpad, outside RAM
  _i(43, 23, 2, 4), // sw r2, 4(r23)
  _i(9, 0, 17, 3), // addiu r17, zero, 3
  _i(9, 0, 18, 0), // addiu r18, zero, 0
  _r(33, 18, 2, 18), // loop: addu r18, r18, r2
  _i(9, 17, 17, -1), // addiu r17, r17, -1
  _i(5, 17, 0, -3), // bne r17, zero, loop
  _i(35, 1, 19, 0), // lw r19, 0(r1) (delay slot)
  _i(1, 18, 1, 1), // bgez r18, +1
  _r(0, 0, 0, 0), // nop (delay slot)
  _i(9, 0, 20, 99), // addiu r20, zero, 99 (skipped)
  _i(1, 2, 17, 1), // bltzal r2, +1: links although not taken
  _r(0, 0, 0, 0), // nop (delay slot)
  _i(9, 0, 21, 0), // addiu r21, zero, sub (patched below)
  _r(9, 21, 0, 30), // jalr r30, r21
  _i(43, 1, 18, 16), // sw r18, 16(r1) (delay slot)
  _i(3, 0, 0, 0), // jal end (patched below)
  _r(0, 0, 0, 0), // nop (delay slot)
  _i(9, 0, 22, 42), // sub: addiu r22, zero, 42
  _r(8, 30, 0, 0), // jr r30 (the jalr link, not the bltzal one)
  _r(0, 0, 0, 0), // nop (delay slot)
  _i(4, 0, 0, -1), // end: beq zero, zero, end
  _r(0, 0, 0, 0), // nop
];

List<int> _words() {
  final words = List.of(_program);
  final sub = _base + (words.length - 6) * 4;
  final end = _base + (words.length - 2) * 4;
  words[words.indexOf(_i(9, 0, 21, 0))] = _i(9, 0, 21, sub);
  words[words.indexOf(_i(3, 0, 0, 0))] =
      3 << 26 | ((end >> 2) & 0x3ffffff);
  return words;
}

final _bios = Uint8List(512 * 1024);

(Iop, IopMemory) _load(IopJit? jit, [List<int>? words]) {
  final memory = IopMemory(_bios, ram: jit?.ram);
  final cpu = Iop(memory, regs: jit?.regs);
  jit?.attach(cpu, memory);
  final program = words ?? _words();
  for (var i = 0; i < program.length; i++) {
    memory.write32(_base + i * 4, program[i]);
  }
  memory.write32(_data, 0x12345678);
  memory.write32(_data + 4, 0xffffff9c);
  cpu.jump(_base);
  return (cpu, memory);
}

void _expectSame(Iop cpu, IopMemory memory, Iop expected,
    IopMemory expectedMemory, String name) {
  expect(cpu.pc, expected.pc, reason: '$name pc');
  expect(cpu.nextPc, expected.nextPc, reason: '$name nextPc');
  expect(cpu.clocks, expected.clocks, reason: '$name clocks');
  expect(cpu.hi, expected.hi, reason: '$name hi');
  expect(cpu.lo, expected.lo, reason: '$name lo');
  expect(cpu.pendingLoad(), expected.pendingLoad(),
      reason: '$name pending load');
  for (var r = 0; r < 32; r++) {
    expect(cpu.r[r], expected.r[r], reason: '$name r$r');
    expect(cpu.cop0[r], expected.cop0[r], reason: '$name cop0[$r]');
  }
  expect(memory.ram, expectedMemory.ram, reason: '$name ram');
  expect(memory.scratch, expectedMemory.scratch, reason: '$name scratch');
}

void _compare(IopJit? jit, String name, {int clocks = 300}) {
  final end = _base + (_words().length - 2) * 4;
  final (expected, expectedMemory) = _load(null);
  while (expected.pc != end) {
    expected.step();
  }
  final (cpu, memory) = _load(jit);
  var compiled = 0;
  for (var guard = 0; cpu.pc != end && guard < 100000; guard++) {
    final ran = jit?.run(16) ?? 0;
    if (ran > 0) {
      compiled += ran;
    } else {
      cpu.step();
    }
  }
  expect(compiled, greaterThan(0), reason: '$name ran no compiled code');
  // Both sides are in the end loop now. Step the interpreter alone up
  // to the target, then step each side until the clocks are equal, so
  // both stop at the same point of the loop.
  while (expected.clocks < clocks) {
    expected.step();
  }
  while (cpu.clocks < expected.clocks) {
    cpu.step();
  }
  while (expected.clocks < cpu.clocks) {
    expected.step();
  }
  _expectSame(cpu, memory, expected, expectedMemory, name);
}

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

  aggCase('compiled IOP code matches the interpreter', () {
    final jit = IopJit.create(compileThreshold: 1);
    if (jit == null) return; // no little-endian host
    addTearDown(jit.dispose);
    _compare(jit, 'native');
  });

  aggCase('reference IR IOP code matches the interpreter', () {
    final jit = IopJit.create(native: false, compileThreshold: 1)!;
    addTearDown(jit.dispose);
    _compare(jit, 'reference');
  });

  aggCase('an overflowing add hands its state to the interpreter', () {
    for (final jit in [
      IopJit.create(compileThreshold: 1),
      IopJit.create(native: false, compileThreshold: 1),
    ]) {
      if (jit == null) return;
      addTearDown(jit.dispose);
      final words = [
        _i(15, 0, 7, 0x7fff), // lui r7, 0x7fff
        _i(13, 7, 7, 0xffff), // ori r7, r7, 0xffff
        _i(9, 0, 8, 1), // addiu r8, zero, 1
        _i(35, 0, 5, _data), // lw r5, data(zero): in flight at the add
        _r(32, 7, 8, 6), // add r6, r7, r8: overflows
        _i(9, 0, 9, 1), // addiu r9, zero, 1
      ];
      final (expected, expectedMemory) = _load(null, words);
      for (var i = 0; i < 5; i++) {
        expected.step();
      }
      final (cpu, memory) = _load(jit, words);
      for (var guard = 0; cpu.clocks < 5 && guard < 100; guard++) {
        if (jit.run(5 - cpu.clocks) == 0) cpu.step();
      }
      _expectSame(cpu, memory, expected, expectedMemory, 'overflow');
      expect(cpu.pc, 0xbfc00180); // the BEV exception vector
      expect(cpu.r[5], 0x12345678); // the load landed on the fault step
      expect(cpu.r[6], 0);
    }
  });

  aggCase('a misaligned load hands its state to the interpreter', () {
    final jit = IopJit.create(compileThreshold: 1);
    if (jit == null) return;
    addTearDown(jit.dispose);
    final words = [
      _i(35, 0, 5, _data), // lw r5, data(zero): in flight at the fault
      _i(35, 0, 6, _data + 2), // lw r6, data+2(zero): misaligned
      _i(9, 0, 9, 1), // addiu r9, zero, 1
    ];
    final (expected, expectedMemory) = _load(null, words);
    for (var i = 0; i < 2; i++) {
      expected.step();
    }
    final (cpu, memory) = _load(jit, words);
    for (var guard = 0; cpu.clocks < 2 && guard < 100; guard++) {
      if (jit.run(2 - cpu.clocks) == 0) cpu.step();
    }
    _expectSame(cpu, memory, expected, expectedMemory, 'misaligned');
    expect(cpu.pc, 0xbfc00180);
    expect(cpu.cop0[Iop.cop0BadVAddr], _data + 2);
    expect(cpu.r[5], 0x12345678);
    expect(cpu.r[6], 0);
  });

  aggCase('MFC0 of Cause sees the interrupt line mirror', () {
    final jit = IopJit.create(compileThreshold: 1);
    if (jit == null) return;
    addTearDown(jit.dispose);
    final words = [
      _cop0(0, rt: 5, rd: Iop.cop0Cause), // mfc0 r5, Cause
      _r(0, 0, 0, 0), // nop: the mfc0 lands after it
      _i(4, 0, 0, -1), // end: beq zero, zero, end
      _r(0, 0, 0, 0), // nop
    ];
    final (expected, _) = _load(null, words);
    expected.setInterrupt(true);
    for (var i = 0; i < 10; i++) {
      expected.step();
    }
    final (cpu, _) = _load(jit, words);
    cpu.setInterrupt(true);
    for (var guard = 0; cpu.clocks < 10 && guard < 100; guard++) {
      if (jit.run(10 - cpu.clocks) == 0) cpu.step();
    }
    expect(cpu.r[5], expected.r[5]);
    expect(cpu.r[5] & 0x400, isNonZero);
  });

  const chunkCount = 1;
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
