import 'dart:math';

import 'package:fnesemu_core/src/core/n64/bus.dart';
import 'package:fnesemu_core/src/core/n64/cpu.dart';
import 'package:fnesemu_core/src/core/n64/jit/n64_jit.dart';
import 'package:fnesemu_core/src/core/n64/jit/vr4300_translator.dart';
import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

const _pc = 0x80001000;
int _i(int op, int s, int t, int immediate) =>
    op << 26 | s << 21 | t << 16 | (immediate & 0xffff);
int _r(int s, int t, int d, int fn, [int shift = 0]) =>
    s << 21 | t << 16 | d << 11 | shift << 6 | fn;

final class _Machine {
  final N64Jit? jit;
  late final N64Bus bus = N64Bus(ram: jit?.ram);
  late final Vr4300 cpu = Vr4300(bus, registers: jit?.regs, fpu: jit?.fpu);
  _Machine(this.jit) {
    jit?.attach(cpu, bus);
  }
  void load(List<int> code, {int seed = 7}) {
    jit?.reset();
    bus.ram.fillRange(0, 0x6000, 0);
    bus.mi.fillRange(0, bus.mi.length, 0);
    bus.audioCycles = 0;
    cpu.reset(_pc);
    final rnd = Random(seed);
    for (var i = 1; i < 32; i++) {
      cpu.r[i] = rnd.nextInt(0x100000000) << 32 | rnd.nextInt(0x100000000);
    }
    cpu.r[28] = 0x80004000.toSigned(32);
    for (var i = 0; i < code.length; i++) {
      bus.ramWrite(0x1000 + i * 4, code[i], 4);
    }
    bus.ramWrite(0x1000 + code.length * 4, 0x70000000, 4);
  }

  void run(int limit) {
    while (cpu.clocks < limit && cpu.stopReason == null) {
      final before = cpu.clocks;
      var budget = min(limit - before, cpu.clocksUntilCompare);
      if (bus.audioCycles > 0) budget = min(budget, bus.audioCycles);
      if (jit?.run(budget) != true) cpu.step();
      bus.tick(cpu.clocks - before);
    }
  }

  void matches(_Machine other, {String? reason}) {
    expect(cpu.r.toList(), other.cpu.r.toList(), reason: reason);
    expect([
      cpu.pc,
      cpu.nextPc,
      cpu.clocks,
      cpu.hi,
      cpu.lo
    ], [
      other.cpu.pc,
      other.cpu.nextPc,
      other.cpu.clocks,
      other.cpu.hi,
      other.cpu.lo
    ], reason: reason);
    expect(cpu.cop0, other.cpu.cop0, reason: reason);
    expect(cpu.stopReason, other.cpu.stopReason, reason: reason);
    expect(
        cpu.fpu.data.buffer.asUint8List(
            cpu.fpu.data.offsetInBytes, cpu.fpu.data.lengthInBytes),
        other.cpu.fpu.data.buffer.asUint8List(
            other.cpu.fpu.data.offsetInBytes, other.cpu.fpu.data.lengthInBytes),
        reason: reason);
    expect((
      cpu.fpu.control,
      cpu.fpu.wide
    ), (
      other.cpu.fpu.control,
      other.cpu.fpu.wide
    ), reason: reason);
    expect(
        bus.ram.sublist(0x1000, 0x5000), other.bus.ram.sublist(0x1000, 0x5000),
        reason: reason);
    expect(bus.mi, other.bus.mi, reason: reason);
    expect(bus.audioCycles, other.bus.audioCycles, reason: reason);
  }

  void dispose() => jit?.dispose();
}

void main() {
  test('CPU profiling preserves faults, registers, memory and clocks', () {
    final expected = _Machine(null);
    final actual =
        _Machine(N64Jit.create(native: false, compileThreshold: 100000)!);
    addTearDown(actual.dispose);
    for (final machine in [expected, actual]) {
      machine.load([
        _i(9, 0, 1, 42),
        _i(0x2b, 28, 1, 0),
        _i(0x23, 28, 2, 0),
        _i(0x23, 28, 3, 1)
      ]);
    }
    final stats = actual.jit!.diagnostics.enableExecutionStats();
    for (var i = 0; i < 4; i++) {
      actual.cpu.step();
      expected.cpu.step();
    }
    actual.matches(expected);
    expect(stats.cpuClocks, actual.cpu.clocks);
    expect(stats.cpuDispatches, 4);
    expect((stats.report()['memory'] as List).map((e) => e['kind']),
        containsAll(['fetch', 'read', 'write']));
    actual.jit!.recordIdle(7);
    expect(stats.idleClocks, 7);
    actual.jit!.diagnostics.disableExecutionStats();
    expect(actual.cpu.executionStats, isNull);
  });

  for (final native in [false, true]) {
    group(native ? 'native' : 'reference IR', () {
      late _Machine reference, actual;
      setUp(() {
        reference = _Machine(null);
        actual = _Machine(N64Jit.create(
            native: native, compileThreshold: 1, inlineJumps: true)!);
      });
      tearDown(() => actual.dispose());


      test('big endian signed and unsigned memory operations agree', () {
        final code = [
          _i(63, 28, 1, 0),
          _i(55, 28, 2, 0),
          _i(43, 28, 3, 8),
          _i(35, 28, 4, 8),
          _i(39, 28, 5, 8),
          _i(41, 28, 6, 12),
          _i(33, 28, 7, 12),
          _i(37, 28, 8, 12),
          _i(40, 28, 9, 14),
          _i(32, 28, 10, 14),
          _i(36, 28, 11, 14),
        ];
        for (final m in [reference, actual]) m.load(code);
        actual.run(code.length);
        reference.run(max(code.length, actual.cpu.clocks));
        actual.matches(reference);
        expect(actual.jit!.compiledClocks, native ? code.length : 0);
      });












      test('native FP compares match the CPU for zeros, signs and widths', () {
        actual.dispose();
        actual = _Machine(N64Jit.create(
            native: native,
            compileThreshold: 1,
            nativeFpu: true,
            fpuHelpers: false)!);
        const values = [
          0.0,
          -0.0,
          1e-40,
          -1e-40,
          1.25,
          -1.25,
          2.5,
          -2.5,
          double.infinity,
          double.nan
        ];
        for (final wide in [false, true]) {
          for (final fmt in [16, 17]) {
            for (final fn in [0x32, 0x3c, 0x3e]) {
              for (final control in [0x1, 0x800001]) {
                for (final x in values) {
                  for (final y in values) {
                    final compare =
                        17 << 26 | fmt << 21 | 4 << 16 | 2 << 11 | fn;
                    final code = [compare, 0x4445f800];
                    for (final m in [reference, actual]) {
                      m.load(code);
                      m.cpu.fpu.wide = wide;
                      m.cpu.fpu.control = control;
                      m.cpu.fpu.setValue(2, fmt, x);
                      m.cpu.fpu.setValue(4, fmt, y);
                    }
                    actual.run(code.length);
                    reference.run(max(code.length, actual.cpu.clocks));
                    actual.matches(reference,
                        reason: 'FR=$wide fmt=$fmt fn=$fn $x $y');
                    if (native && x.isFinite && y.isFinite) {
                      expect(actual.jit!.compiledClocks, code.length);
                    }
                  }
                }
              }
            }
          }
        }
      });











    },
        skip: native && !JitRuntime.nativeSupported
            ? 'No compiled backend'
            : false);
  }
}
