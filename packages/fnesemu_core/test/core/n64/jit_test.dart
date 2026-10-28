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
  test('direct jump inlining guards non-contiguous code and bounds loops', () {
    final code = <int, int>{
      _pc: 0x08000800,
      _pc + 4: _i(9, 1, 1, 1),
      0x80002000: _i(9, 2, 2, 1),
      0x80002004: 0x08000400,
      0x80002008: _i(9, 3, 3, 1),
    };
    final protected = <int>[];
    final block = Vr4300Translator(
            fetch: (pc) => code[pc], protect: protected.add, inlineJumps: true)
        .translate(_pc)!;
    expect(block.cost, 5);
    expect(block.term, isA<IrJump>());
    expect((block.term as IrJump).pc, _pc);
    expect(block.guards.map((g) => g.addr), code.keys);
    expect(protected, code.keys);
    final previous = Vr4300Translator(
            fetch: (pc) => code[pc], protect: (_) {}, inlineJumps: false)
        .translate(_pc)!;
    expect(previous.cost, 2);
    expect(previous.guards.length, 2);
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

      test('random word and doubleword operations preserve all register bits',
          () {
        final rnd = Random(17);
        const functions = [
          0,
          2,
          3,
          4,
          6,
          7,
          33,
          35,
          36,
          37,
          38,
          39,
          42,
          43,
          45,
          47,
          56,
          58,
          59,
          60,
          62,
          63
        ];
        const immediates = [9, 10, 11, 12, 13, 14, 15, 25];
        for (var trial = 0; trial < 100; trial++) {
          final code = List.generate(80, (_) {
            final s = rnd.nextInt(28), t = rnd.nextInt(28), d = rnd.nextInt(28);
            return rnd.nextBool()
                ? _r(s, t, d, functions[rnd.nextInt(functions.length)],
                    rnd.nextInt(32))
                : _i(immediates[rnd.nextInt(immediates.length)], s, t,
                    rnd.nextInt(65536));
          });
          for (final m in [reference, actual]) m.load(code, seed: trial);
          for (final stop in [1, 23, 24, 25, 79, 80]) {
            actual.run(stop);
            reference.run(max(stop, actual.cpu.clocks));
            actual.matches(reference, reason: 'trial $trial clock $stop');
          }
          for (final m in [reference, actual]) m.load(code, seed: trial);
          actual.run(80);
          reference.run(max(80, actual.cpu.clocks));
          actual.matches(reference, reason: 'whole trial $trial');
          if (native) expect(actual.jit!.compiledClocks, 80);
        }
      });

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

      test('branches read pre-slot operands and preserve delay-slot writes',
          () {
        final code = [
          _i(9, 0, 1, 8),
          _i(9, 1, 1, -1),
          _i(5, 1, 0, -2),
          _i(9, 2, 2, 1),
          _r(1, 2, 3, 45),
        ];
        for (final m in [reference, actual]) m.load(code);
        for (final stop in [1, 7, 14, 27]) {
          actual.run(stop);
          reference.run(max(stop, actual.cpu.clocks));
          actual.matches(reference, reason: 'clock $stop');
        }
      });

      test('direct jumps and calls preserve links across inlined targets', () {
        final code = [
          _i(9, 0, 1, 7),
          3 << 26 | ((_pc + 20) >> 2) & 0x3ffffff,
          _i(9, 31, 2, 0),
          0x70000000,
          0,
          _i(9, 1, 3, 9),
          2 << 26 | ((_pc + 40) >> 2) & 0x3ffffff,
          _i(9, 3, 4, 1),
          0,
          0,
          _r(3, 4, 5, 33),
          _r(31, 0, 0, 8),
          _i(9, 5, 6, 2),
        ];
        for (final limit in [1, 2, 3, 6, 9, 10]) {
          for (final m in [reference, actual]) m.load(code);
          actual.run(limit);
          reference.run(max(limit, actual.cpu.clocks));
          actual.matches(reference, reason: 'budget=$limit');
          if (native && limit == 9) expect(actual.jit!.compiledClocks, 9);
        }
      });

      test('inlined targets retain guards after host modifications', () {
        final code = [
          0x08000404,
          _i(9, 1, 1, 1),
          0,
          0,
          _i(9, 2, 2, 1),
          0x08000400,
          _i(9, 3, 3, 1)
        ];
        for (final m in [reference, actual]) m.load(code);
        actual.run(30);
        reference.run(max(30, actual.cpu.clocks));
        actual.matches(reference);
        for (final m in [reference, actual]) {
          m.bus.write(0xa0001010, _i(9, 2, 2, 3), 4);
        }
        actual.run(60);
        reference.run(max(60, actual.cpu.clocks));
        actual.matches(reference);
      });

      test('slot memory exit restores the state before the link branch', () {
        final code = [0x0c000800, _i(35, 28, 31, 1), 0];
        for (final m in [reference, actual]) m.load(code);
        actual.run(3);
        reference.run(max(3, actual.cpu.clocks));
        actual.matches(reference);
        expect(actual.cpu.stopReason, contains('Unaligned'));
      });

      test('stores to translated instructions leave before modifying code', () {
        final replacement = _i(9, 0, 2, 99);
        final code = [_i(43, 28, 1, 0), 0, _i(9, 0, 2, 1), 0];
        for (final m in [reference, actual]) {
          m.load(code);
          m.cpu.r[28] = (_pc + 8).toSigned(32);
          m.cpu.r[1] = replacement;
        }
        actual.run(4);
        reference.run(max(4, actual.cpu.clocks));
        actual.matches(reference);
        expect(actual.cpu.r[2], 99);
      });

      test('interrupts passed inside a block are taken at its end', () {
        // A 20-instruction block passes both the Compare match (clock 14)
        // and audio completion (clock 9) before it ends.
        final code = [
          for (var i = 0; i < 20; i++) _i(9, 1, 1, 1),
          _i(4, 0, 0, -21),
          0,
        ];
        // ADDIU sign-extends word results; count increments in the low word.
        final start = <_Machine, int>{};
        int added(_Machine m) => (m.cpu.r[1] - start[m]!).toUnsigned(32);
        for (final m in [reference, actual]) {
          m.load(code);
          m.cpu.cop0[11] = 7;
          m.cpu.cop0[12] = 0x8401;
          m.bus.mi[3] = 4;
          m.bus.audioCycles = 9;
          start[m] = m.cpu.r[1];
        }
        actual.run(40);
        reference.run(max(40, actual.cpu.clocks));
        for (final m in [reference, actual]) {
          // Neither interrupt is lost, including the passed timer match.
          expect(m.cpu.cop0[12] & 2, 2);
          expect(m.cpu.cop0[13] & 0x8400, 0x8400);
        }
        // The CPU takes the audio interrupt at the next instruction; the
        // compiled block completes first, so its exception follows the block.
        expect(added(reference), lessThan(20));
        expect(added(actual), 20);
        expect(actual.cpu.cop0[14].toUnsigned(32), _pc);
      });

      test('trapping word arithmetic preserves overflow and delay state', () {
        for (final instruction in [
          _i(8, 1, 3, 1),
          _r(1, 2, 3, 32),
          _r(1, 2, 3, 34)
        ]) {
          for (final x in [0, 1, 0x7fffffff, -0x80000000, -1]) {
            for (final y in [1, -1, 0x7fffffff, -0x80000000]) {
              for (final slot in [false, true]) {
                final code = [
                  if (slot) 0x0c000408,
                  instruction,
                  _i(9, 0, 4, 7)
                ];
                for (final m in [reference, actual]) {
                  m.load(code);
                  m.cpu.r[1] = x;
                  m.cpu.r[2] = y;
                }
                actual.run(slot ? 2 : 1);
                reference.run(max(slot ? 2 : 1, actual.cpu.clocks));
                actual.matches(reference,
                    reason: '$instruction $x $y slot=$slot');
              }
            }
          }
        }
      });

      test('COP1 transfer and native arithmetic modes preserve state', () {
        for (final arithmetic in [false, true]) {
          actual.dispose();
          actual = _Machine(N64Jit.create(
              native: native,
              compileThreshold: 1,
              cop1: true,
              nativeFpu: arithmetic,
              fpuHelpers: false)!);
          for (final taken in [false, true]) {
            final code = [
              0x44811000,
              0x44031000,
              _i(57, 28, 2, 0),
              _i(49, 28, 4, 0),
              0x44c5f800,
              _i(17, 8, 3, 2),
              _i(9, 0, 6, 7),
              _i(9, 0, 7, 9),
              0x4448f800
            ];
            for (final m in [reference, actual]) {
              m.load(code);
              m.cpu.r[1] = 0x3fa00000;
              m.cpu.r[5] = taken ? 1 << 23 : 0;
            }
            actual.run(9);
            reference.run(max(9, actual.cpu.clocks));
            actual.matches(reference, reason: 'transfer branch $taken');
          }
          for (final wide in [false, true]) {
            for (final fmt in [16, 17]) {
              for (final fn in [0, 1, 2]) {
                for (final value in [
                  0.0,
                  -0.0,
                  1.25,
                  -2.5,
                  1e-40,
                  double.infinity,
                  double.nan
                ]) {
                  final fp =
                      17 << 26 | fmt << 21 | 4 << 16 | 2 << 11 | 6 << 6 | fn;
                  final code = [_i(9, 0, 1, 9), fp, 0x44023000, _i(9, 1, 3, 2)];
                  for (final m in [reference, actual]) {
                    m.load(code);
                    m.cpu.fpu.wide = wide;
                    m.cpu.fpu.setValue(2, fmt, value);
                    m.cpu.fpu.setValue(4, fmt, 2.5);
                  }
                  actual.run(code.length);
                  reference.run(max(code.length, actual.cpu.clocks));
                  actual.matches(reference,
                      reason: '$arithmetic FR=$wide fmt=$fmt fn=$fn $value');
                  if (native && arithmetic && value.isFinite) {
                    expect(actual.jit!.compiledClocks, code.length);
                  }
                }
              }
            }
          }
        }
      });

      test('native FP slot exits restore branch links and prior integer state',
          () {
        actual.dispose();
        actual = _Machine(N64Jit.create(
            native: native,
            compileThreshold: 1,
            nativeFpu: true,
            fpuHelpers: false)!);
        for (final fmt in [16, 17]) {
          for (final value in [1.25, double.infinity, double.nan]) {
            final fp = 17 << 26 | fmt << 21 | 4 << 16 | 2 << 11 | 2 << 6;
            final code = [
              _i(9, 0, 1, 9),
              0x0c000404,
              fp,
              _i(9, 0, 3, 7),
              0x44021000
            ];
            for (final m in [reference, actual]) {
              m.load(code);
              m.cpu.fpu.setValue(2, fmt, value);
              m.cpu.fpu.setValue(4, fmt, 2.5);
            }
            actual.run(4);
            reference.run(max(4, actual.cpu.clocks));
            actual.matches(reference, reason: 'slot fmt=$fmt $value');
          }
        }
      });

      test('floating point preserves unusable exceptions', () {
        final code = [
          _i(15, 0, 1, 0x3f80),
          0x44810800,
          0x46010880,
          0x44021000,
          _i(9, 2, 3, 1)
        ];
        for (final enabled in [true, false]) {
          for (final m in [reference, actual]) {
            m.load(code);
            if (!enabled) m.cpu.cop0[12] &= ~(1 << 29);
          }
          actual.run(5);
          reference.run(max(5, actual.cpu.clocks));
          actual.matches(reference);
          if (enabled) expect(actual.cpu.r[2], 0x40000000);
        }
      });

      test('COP1 transfers, helpers and big endian memory share both layouts',
          () {
        int fp(int fmt, int ft, int fs, int fd, int fn) =>
            17 << 26 | fmt << 21 | ft << 16 | fs << 11 | fd << 6 | fn;
        for (final wide in [false, true]) {
          final code = [
            fp(5, 1, 3, 0, 0), // DMTC1
            fp(1, 2, 3, 0, 0), // DMFC1
            fp(4, 4, 5, 0, 0), // MTC1
            fp(0, 6, 5, 0, 0), // MFC1
            _i(61, 28, 3, 0), _i(53, 28, 7, 0),
            _i(57, 28, 5, 8), _i(49, 28, 9, 8),
            fp(6, 0, 31, 0, 0), // CTC1
            fp(16, 9, 5, 11, 0), // ADD.S
            fp(16, 0, 11, 13, 36), // CVT.W.S
            fp(0, 8, 13, 0, 0),
            fp(2, 10, 31, 0, 0), fp(2, 12, 0, 0, 0),
            _r(2, 8, 14, 45),
          ];
          for (final m in [reference, actual]) {
            m.load(code);
            m.cpu.fpu.wide = wide;
            m.cpu.r[1] = 0x4008000080000001;
            m.cpu.r[4] = 0x3fc00000;
          }
          actual.run(code.length);
          reference.run(max(code.length, actual.cpu.clocks));
          actual.matches(reference, reason: 'FR=$wide');
          if (native) expect(actual.jit!.compiledClocks, code.length);
        }
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

      test('native FP conversions match the CPU across rounding modes', () {
        actual.dispose();
        actual = _Machine(N64Jit.create(
            native: native,
            compileThreshold: 1,
            nativeFpu: true,
            fpuHelpers: false)!);
        const values = [
          0.0, -0.0, 0.5, -0.5, 1.5, 2.5, -2.5, 1e-40, -1e-310, //
          123456.75, -98765.5, 2147483520.0, -2147483648.0, 3e9, -3e9,
          1e300, double.infinity, double.nan,
        ];
        const ops = [
          (16, 12), (17, 12), (16, 13), (17, 13), (16, 36), //
          (17, 36), (17, 32), (16, 33)
        ];
        for (final wide in [false, true]) {
          for (final (fmt, fn) in ops) {
            for (final control in [0, 1, 3]) {
              for (final x in values) {
                final convert = 17 << 26 | fmt << 21 | 2 << 11 | 6 << 6 | fn;
                final code = [convert, 0x4445f800];
                for (final m in [reference, actual]) {
                  m.load(code);
                  m.cpu.fpu.wide = wide;
                  m.cpu.fpu.control = control;
                  m.cpu.fpu.setValue(2, fmt, x);
                }
                actual.run(code.length);
                reference.run(max(code.length, actual.cpu.clocks));
                actual.matches(reference,
                    reason: 'FR=$wide fmt=$fmt fn=$fn RM=$control $x');
                final source = actual.cpu.fpu.value(2, fmt);
                final native_ = source.isFinite &&
                    (fn == 32 || fn == 33 || source.abs() < 2147483648.0) &&
                    (fn != 36 || control == 0) &&
                    source != -2147483648.0;
                if (native && native_) {
                  expect(actual.jit!.compiledClocks, code.length,
                      reason: 'native FR=$wide fmt=$fmt fn=$fn $x');
                }
              }
            }
          }
        }
      });

      test('FP compare and likely branches annul only untaken slots', () {
        for (final wide in [false, true]) {
          for (final taken in [false, true]) {
            for (final likely in [false, true]) {
              final code = [
                0x46020832, // C.EQ.S f1, f2
                _i(17, 8, 1 | (likely ? 2 : 0), 2),
                _i(9, 0, 3, 7),
                _i(9, 0, 4, 9),
                0x4445f800, // CFC1 r5, FCSR
              ];
              for (final m in [reference, actual]) {
                m.load(code);
                m.cpu.fpu.wide = wide;
                m.cpu.fpu.setValue(1, 16, 1.25);
                m.cpu.fpu.setValue(2, 16, taken ? 1.25 : 2.5);
              }
              actual.run(6);
              reference.run(max(6, actual.cpu.clocks));
              actual.matches(reference);
              if (native) expect(actual.jit!.compiledClocks, greaterThan(0));
            }
          }
        }
      });

      test('untaken likely branches chain without returning through Dart', () {
        actual.dispose();
        actual = _Machine(N64Jit.create(
            native: native, statistics: true, compileThreshold: 1)!);
        final code = [
          _i(20, 1, 2, 3),
          _i(9, 0, 3, 7),
          _i(9, 0, 4, 9),
          _i(9, 0, 5, 11)
        ];
        for (final m in [reference, actual]) {
          m.load(code);
          m.cpu.r[1] = 0;
          m.cpu.r[2] = 1;
        }
        actual.run(3);
        actual.cpu.reset(_pc);
        actual.cpu.r.setAll(0, reference.cpu.r);
        actual.jit!.runtimeExits!.clear();
        actual.run(3);
        reference.run(max(3, actual.cpu.clocks));
        actual.matches(reference);
        expect(actual.jit!.runtimeExits!.values.fold(0, (a, b) => a + b), 1);
      });

      test('integer likely branches and link slots preserve exact budgets', () {
        for (final opcode in [1, 20, 21, 22, 23]) {
          for (final taken in [false, true]) {
            for (final limit in [1, 2, 3, 5]) {
              final code = [
                _i(opcode, 1, opcode == 1 ? 18 : 0, 2),
                _i(9, 31, 2, 1),
                _i(9, 0, 3, 9),
                _i(9, 0, 4, 7),
              ];
              for (final m in [reference, actual]) {
                m.load(code);
                m.cpu.r[1] = taken ? -1 : 0;
              }
              actual.run(limit);
              reference.run(max(limit, actual.cpu.clocks));
              actual.matches(reference,
                  reason: 'op=$opcode taken=$taken budget=$limit');
            }
          }
        }
      });

      test('HI/LO moves and 32-bit multiplies match the CPU', () {
        const values = [
          0, 1, -1, 2, 0x7fffffff, 0x80000000, 0xffffffff, 0x12345678, //
          0x80000001, 0x0000ffff, 0x00010000, 0xdeadbeef,
        ];
        for (final overflow in [false, true]) {
          final code = [
            _r(1, 2, 0, 24), // MULT
            _r(0, 0, 3, 18), // MFLO
            _r(0, 0, 4, 16), // MFHI
            _r(1, 2, 0, 25), // MULTU
            _r(0, 0, 5, 18),
            _r(0, 0, 6, 16),
            _r(1, 0, 0, 17), // MTHI
            _r(2, 0, 0, 19), // MTLO
            _r(0, 0, 7, 16),
            _r(0, 0, 8, 18),
            if (overflow) _r(10, 10, 9, 32), // ADD traps before the end
            _r(1, 2, 0, 24),
          ];
          for (final x in values) {
            for (final y in values) {
              for (final upper in [0, 0x1234abcd]) {
                for (final m in [reference, actual]) {
                  m.load(code);
                  m.cpu.r[1] = x | upper << 32;
                  m.cpu.r[2] = y | (upper ^ 0x7fff0001) << 32;
                  m.cpu.r[10] = 0x40000000;
                  m.cpu.hi = 0x1111222233334444;
                  m.cpu.lo = -0x5555666677778888;
                }
                actual.run(code.length);
                reference.run(max(code.length, actual.cpu.clocks));
                actual.matches(reference,
                    reason: 'overflow=$overflow $x $y $upper');
                if (native && !overflow) {
                  expect(actual.jit!.compiledClocks, code.length);
                }
              }
            }
          }
        }
      });

      test('FP helpers preserve special values and live integer operands', () {
        for (final fmt in [16, 17]) {
          for (final value in [
            double.nan,
            double.infinity,
            -double.infinity,
            -0.0,
            1.5,
            -2.5
          ]) {
            final code = <int>[_i(9, 1, 3, 7)];
            for (final fn in [
              0,
              1,
              2,
              3,
              4,
              5,
              6,
              7,
              8,
              9,
              10,
              11,
              12,
              13,
              14,
              15,
              32,
              33,
              36,
              37,
              48,
              50,
              52,
              54
            ]) {
              code.add(17 << 26 | fmt << 21 | 2 << 16 | 1 << 11 | 4 << 6 | fn);
            }
            code.add(_r(3, 1, 5, 45));
            for (final m in [reference, actual]) {
              m.load(code);
              m.cpu.fpu.setValue(1, fmt, value);
              m.cpu.fpu.setValue(2, fmt, 2.0);
            }
            actual.run(code.length);
            reference.run(max(code.length, actual.cpu.clocks));
            actual.matches(reference, reason: 'fmt=$fmt value=$value');
          }
        }
      });

      test('FP memory faults in link slots replay the branch precisely', () {
        for (final opcode in [49, 53, 57, 61]) {
          for (final address in [0x80004001, 0x00400000, 0xa4400000]) {
            final code = [0x0c000800, _i(opcode, 28, 3, 0), 0];
            for (final m in [reference, actual]) {
              m.load(code);
              m.cpu.r[28] = address.toSigned(32);
              m.cpu.fpu.setLong(3, 0x4008000080000001);
            }
            actual.run(3);
            reference.run(max(3, actual.cpu.clocks));
            actual.matches(reference);
          }
        }
      });

      test('FPU mode changes select a different cached block', () {
        final code = [0x44810800, 0x44020800, 0x08000400, 0];
        for (final m in [reference, actual]) m.load(code);
        for (final wide in [false, true, false]) {
          for (final m in [reference, actual]) {
            m.cpu.fpu.wide = wide;
            m.cpu.r[1]++;
          }
          final end = reference.cpu.clocks + 20;
          actual.run(end);
          reference.run(max(end, actual.cpu.clocks));
          actual.matches(reference);
        }
        for (final m in [reference, actual]) m.cpu.cop0[12] &= ~(1 << 29);
        actual.run(65);
        reference.run(max(65, actual.cpu.clocks));
        actual.matches(reference);
      });

      test('host writes invalidate guards through either RAM alias', () {
        final code = [_i(9, 1, 1, 1), 0x08000400, 0];
        for (final m in [reference, actual]) m.load(code);
        actual.run(30);
        reference.run(max(30, actual.cpu.clocks));
        actual.matches(reference);
        for (final m in [reference, actual]) {
          m.bus.write(0xa0001000, _i(9, 1, 1, 2), 4);
        }
        actual.run(60);
        reference.run(max(60, actual.cpu.clocks));
        actual.matches(reference);
        if (native) expect(actual.jit!.compiledClocks, greaterThan(0));
      });

      test('TLB addresses use the CPU', () {
        final code = [_i(9, 0, 1, 7), _i(35, 28, 2, 0), 0];
        for (final m in [reference, actual]) {
          m.load(code);
          m.cpu.r[28] = 0x00400000;
        }
        actual.run(8);
        reference.run(max(8, actual.cpu.clocks));
        actual.matches(reference);
        expect(actual.cpu.cop0[8], 0x00400000);
      });
    },
        skip: native && !JitRuntime.nativeSupported
            ? 'No compiled backend'
            : false);
  }
}
