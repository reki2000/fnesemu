import 'dart:math';
import 'dart:typed_data';

import 'package:fnesemu_core/src/components/sh2/jit/jit.dart';
import 'package:fnesemu_core/src/components/sh2/jit/translator.dart';
import 'package:fnesemu_core/src/core/ss/cpu.dart';
import 'package:fnesemu_core/src/core/ss/sh2/sh2.dart';
import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:mp_jit_recompiler/src/optimizer.dart';
import 'package:test/test.dart';

const _base = 0x06000000;

final class _Bus implements SsCpuBus {
  final Uint8List ram;
  late final ByteData data = ByteData.sublistView(ram);
  _Bus(this.ram);
  @override
  int read8(int a) => ram[a & 0xfffff];
  @override
  int read16(int a) => data.getUint16(a & 0xffffe);
  @override
  int read32(int a) => data.getUint32(a & 0xffffc);
  @override
  void write8(int a, int v) => ram[a & 0xfffff] = v;
  @override
  void write16(int a, int v) => data.setUint16(a & 0xffffe, v);
  @override
  void write32(int a, int v) => data.setUint32(a & 0xffffc, v);
}

final class _Machine {
  final Sh2Jit? jit;
  late final Uint8List ram = jit?.rt.alloc(0x100000) ?? Uint8List(0x100000);
  late final _Bus bus = _Bus(ram);
  late final Sh2 cpu = Sh2(bus, jit: jit)..idleSkip = false;
  _Machine(this.jit) {
    jit?.map(_base, ram.length, ram);
    jit?.map(_base + 0x100000, ram.length, ram);
    cpu.pc = _base;
  }
  void load(List<int> code) {
    for (var i = 0; i < code.length; i++) {
      bus.write16(_base + i * 2, code[i]);
    }
  }

  void matches(_Machine other, {bool memory = true}) {
    expect(cpu.r, other.cpu.r);
    expect([
      cpu.pc,
      cpu.clocks,
      cpu.sr,
      cpu.gbr,
      cpu.vbr,
      cpu.pr,
      cpu.mach,
      cpu.macl,
      cpu.lastOpcode
    ], [
      other.cpu.pc,
      other.cpu.clocks,
      other.cpu.sr,
      other.cpu.gbr,
      other.cpu.vbr,
      other.cpu.pr,
      other.cpu.mach,
      other.cpu.macl,
      other.cpu.lastOpcode
    ]);
    if (memory) expect(ram, other.ram);
  }

  void dispose() => jit?.dispose();
}

void main() {
  test('CPU profiling preserves registers, memory and clocks', () {
    final expected = _Machine(null);
    final actual = _Machine(Sh2Jit.create(native: false, compileThreshold: 100000)!);
    addTearDown(actual.dispose);
    for (final machine in [expected, actual]) {
      machine.load([0x6212, 0x7201, 0x2122, 0xaffb, 9]);
      machine.cpu.r[1] = _base + 0x100;
      machine.bus.write32(_base + 0x100, 42);
    }
    final stats = actual.jit!.diagnostics.enableExecutionStats();
    expect(actual.cpu.run(120), isTrue);
    expect(expected.cpu.run(120), isTrue);
    actual.matches(expected);
    expect(stats.cpuClocks, actual.cpu.clocks);
    expect(stats.cpuDispatches, greaterThan(0));
    final requests = stats.report()['memory'] as List;
    expect(requests.map((e) => e['kind']), containsAll(['fetch', 'read', 'write']));
    final before = stats.report();
    actual.bus.read32(_base);
    expect(stats.report(), before);
    actual.jit!.diagnostics.disableExecutionStats();
    expect(actual.cpu.executionStats, isNull);
    actual.cpu.exec();
    expect(stats.report(), before);
  });
  test('sleep fast-forward and interrupt service have separate clock totals', () {
    final machine = _Machine(Sh2Jit.create(native: false)!);
    addTearDown(machine.dispose);
    machine.load([0x001b, 9]);
    machine.cpu.idleSkip = true;
    machine.cpu.r[15] = _base + 0x2000;
    machine.bus.write32(11 * 4, _base + 2);
    final stats = machine.jit!.diagnostics.enableExecutionStats();
    expect(machine.cpu.run(100), isTrue);
    expect(stats.cpuDispatches, 1);
    expect(stats.cpuClocks, greaterThan(0));
    expect(stats.cpuClocks + stats.idleClocks, 100);
    final idle = stats.idleClocks, dispatches = stats.cpuDispatches;
    machine.cpu.nmi();
    expect(machine.cpu.exec(), isTrue);
    expect(stats.cpuDispatches, dispatches + 1);
    expect(stats.idleClocks, idle);
    expect(stats.cpuClocks + stats.idleClocks, machine.cpu.clocks);
    expect((stats.report()['memory'] as List).map((e) => e['kind']),
        containsAll(['fetch', 'read', 'write']));
  });
  test('one-pass base specialization removes repeated address checks', () {
    const code = [0x6142, 0x5241, 0x5342, 0x5543];
    IrBlock translate(Map<int, int> bases) => optimizeIrBlock(Sh2Translator(
            fetch: (pc) => code[(pc - _base) ~/ 2],
            protect: (_) {},
            maxInstructions: code.length,
            alignMemory: false)
        .translate(_base, memoryBases: bases)!);
    final general = translate({});
    final specialized = translate({4: _base + 0x1000});
    int checks(IrBlock block) =>
        block.insts.where((i) => i.op == IrOp.exitIf).length;
    // Four range and alignment checks become one base guard.
    expect(checks(general), 8);
    expect(checks(specialized), 1);
    expect(specialized.insts.where((i) => i.op == IrOp.load).length, 4);
    expect(specialized.guards, general.guards);
  });
  final probe = Sh2Jit.create();
  final supported = probe != null;
  probe?.dispose();
  for (final native in [false, true]) {
    group(native ? 'native SH-2' : 'reference IR SH-2', () {
      late _Machine expected, actual;
      setUp(() {
        expected = _Machine(null);
        actual = _Machine(Sh2Jit.create(native: native, compileThreshold: 1)!);
      });
      tearDown(() => actual.dispose());
      void run(List<int> code, int budget,
          {void Function(_Machine)? initialize}) {
        for (final m in [expected, actual]) {
          m.load(code);
          initialize?.call(m);
        }
        // A compiled block may overshoot; the CPU then catches up to it.
        expect(actual.cpu.run(budget), isTrue);
        expect(expected.cpu.run(max(budget, actual.cpu.clocks)), isTrue);
        actual.matches(expected);
      }

      test('carry and signed overflow preserve all other status bits', () {
        const inputs = [0, 1, 0x7fffffff, 0x80000000, 0xfffffffe, 0xffffffff];
        for (final op in [0x312a, 0x312b, 0x312e, 0x312f, 0x612a]) {
          for (final alias in [false, true]) {
            final instruction = alias ? (op & ~0xf0) | 0x10 : op;
            actual.jit!.reset();
            for (final machine in [expected, actual]) {
              machine.load([instruction, 0xffff]);
            }
            for (final left in inputs) {
              for (final right in inputs) {
                for (final carry in [0, 1]) {
                  for (final machine in [expected, actual]) {
                    machine.cpu.pc = _base;
                    machine.cpu.clocks = 0;
                    machine.cpu.r[1] = left;
                    machine.cpu.r[2] = right;
                    machine.cpu.sr = 0x3f2 | carry;
                  }
                  final before = actual.jit!.compiledClocks;
                  expect(actual.cpu.run(1), isTrue);
                  expect(expected.cpu.run(1), isTrue);
                  actual.matches(expected, memory: false);
                  if (native) expect(actual.jit!.compiledClocks - before, 1);
                }
              }
            }
          }
        }
      });
      test('DIV1 covers every Q M T combination and aliased operands', () {
        const inputs = [0, 1, 0x7fffffff, 0x80000000, 0xffffffff];
        for (final op in [0x3124, 0x3114]) {
          actual.jit!.reset();
          for (final machine in [expected, actual]) {
            machine.load([op, 0xffff]);
          }
          for (var flags = 0; flags < 8; flags++) {
            for (final dividend in inputs) {
              for (final divisor in inputs) {
                for (final machine in [expected, actual]) {
                  machine.cpu.pc = _base;
                  machine.cpu.clocks = 0;
                  machine.cpu.r[1] = dividend;
                  machine.cpu.r[2] = divisor;
                  machine.cpu.sr = 0xf2 | ((flags & 6) << 7) | (flags & 1);
                }
                final before = actual.jit!.compiledClocks;
                expect(actual.cpu.run(1), isTrue);
                expect(expected.cpu.run(1), isTrue);
                actual.matches(expected, memory: false);
                if (native) expect(actual.jit!.compiledClocks - before, 1);
              }
            }
          }
        }
      });
      test('division setup and repeated DIV1 remain inside compiled blocks',
          () {
        run([0x0019, ...List.filled(16, 0x3104), 0x4124, 0x611d, 0xffff], 19,
            initialize: (machine) {
          machine.cpu.r[0] = 7 << 16;
          machine.cpu.r[1] = 100;
        });
        expect(actual.cpu.r[1], 14);
        if (native) expect(actual.jit!.compiledClocks, 19);
        for (final machine in [expected, actual]) {
          machine.jit?.reset();
          machine.cpu.pc = _base;
          machine.cpu.clocks = 0;
        }
        run([0x2127, 0x3124, 0xffff], 2, initialize: (machine) {
          machine.cpu.r[1] = 0xfffffc18;
          machine.cpu.r[2] = 7;
          machine.cpu.sr = 0xf2;
        });
        if (native) expect(actual.jit!.compiledClocks, 2);
      });
      test(
          'special-register stack operations preserve values and stack address',
          () {
        for (final kind in [0, 0x10, 0x20]) {
          for (final machine in [expected, actual]) {
            machine.jit?.reset();
            machine.cpu.pc = _base;
            machine.cpu.clocks = 0;
          }
          run([0x4f02 | kind, 0x400a | kind, 0x4f06 | kind, 0xffff], 3,
              initialize: (machine) {
            machine.cpu.r[15] = _base + 0x1004;
            machine.cpu.r[0] = 0;
            machine.cpu.mach = 0x87654321;
            machine.cpu.macl = 0xfedcba98;
            machine.cpu.pr = 0x12345678;
          });
          expect(actual.cpu.r[15], _base + 0x1004);
          expect((actual.cpu.mach, actual.cpu.macl, actual.cpu.pr),
              (0x87654321, 0xfedcba98, 0x12345678));
          if (native) expect(actual.jit!.compiledClocks, 3);
        }
      });
      test('PR stack operations in a call slot preserve the new return address',
          () {
        run([0xb002, 0x4f22, 0xffff, 9, 0x4f26, 0xffff], 4,
            initialize: (machine) {
          machine.cpu.r[15] = _base + 0x1004;
          machine.cpu.pr = 0x12345678;
        });
        expect(actual.cpu.pr, _base + 4);
        expect(actual.cpu.r[15], _base + 0x1004);
        if (native) expect(actual.jit!.compiledClocks, 4);
      });
      test('unmapped special-register accesses restore pre-instruction state',
          () {
        for (final op in [0x4f22, 0x4f26]) {
          actual.jit!.reset();
          actual.load([0xb002, op, 0xffff, 9, 0xffff, 9]);
          actual.cpu.r[15] = 0xfffffe10;
          actual.cpu.pr = 0x12345678;
          expect(actual.jit!.run(_base, 8), isNull);
          expect(actual.cpu.r[15], 0xfffffe10);
          expect(actual.cpu.pr, 0x12345678);
          expect(actual.jit!.rt.ctx[Sh2Translator.writes], 0);
        }
      });

      test('a suspended JIT runs the CPU on the shared state', () {
        actual.jit!.suspended = true;
        run([0x7101, 0xaffd, 9], 40);
        expect(actual.jit!.compiledClocks, 0);
        actual.jit!.suspended = false;
        for (final m in [expected, actual]) {
          m.cpu.pc = _base;
        }
        actual.cpu.run(80);
        expected.cpu.run(max(80, actual.cpu.clocks));
        actual.matches(expected);
        if (native) expect(actual.jit!.compiledClocks, greaterThan(0));
      });

      test('instruction limits chain while unsupported exits remain', () {
        for (final stop in [false, true]) {
          final m = _Machine(Sh2Jit.create(
              native: native,
              compileThreshold: 1,
              maxInstructions: 4,
              stopOnNoStore: stop)!);
          addTearDown(m.dispose);
          m.load([...List.filled(10, 0x7101), 0xffff]);
          final result = m.jit!.run(_base, 16)!;
          expect(result, (_base + 20, 10));
          expect(m.cpu.r[1], 10);
          if (!stop) {
            expect(m.jit!.rt.contains(_base + 8, 0), isTrue);
            expect(m.jit!.run(_base + 20, 6), isNull);
          }
        }
      });
      test('forward calls and returns yield at the original short back edge',
          () {
        final m = _Machine(Sh2Jit.create(
            native: native, compileThreshold: 1, stopOnNoStore: true)!);
        addTearDown(m.dispose);
        m.load([0xb01e, 9, 0xaffc, 9]);
        m.bus.write16(_base + 0x40, 0x000b);
        m.bus.write16(_base + 0x42, 9);
        expect(m.jit!.run(_base, 20), (_base, 9));
        expect(m.jit!.idleCheckPc, _base + 4);
        final before = m.jit!.rt.nativeEntries;
        expect(m.jit!.run(_base, 20), (_base, 9));
        expect(m.jit!.idleCheckPc, _base + 4);
        if (native) expect(m.jit!.rt.nativeEntries - before, 1);
        expect(m.cpu.pr, _base + 4);
      });

      test(
          'self-loop guards retain stable idle observations and chain changing counters',
          () {
        final m = _Machine(Sh2Jit.create(
            native: native, compileThreshold: 1, idleGuards: true)!);
        addTearDown(m.dispose);
        m.load([0x6103, 0xaffd, 9, 0xffff]);
        m.cpu.r[0] = 7;
        expect(m.jit!.run(_base, 64), (_base, 8));
        expect(m.jit!.idleCheckPc, _base);
        expect(m.cpu.r[1], 7);
        expect(m.jit!.run(_base, 64), (_base, 4));
        expect(m.jit!.idleCheckPc, _base);
        m.jit!.reset();
        m.load([0x7101, 0xaffd, 9, 0xffff]);
        m.cpu.r[1] = 0;
        final before = m.jit!.rt.nativeEntries;
        expect(m.jit!.run(_base, 64), (_base, 64));
        expect(m.jit!.idleCheckPc, isNull);
        expect(m.cpu.r[1], 16);
        if (native) expect(m.jit!.rt.nativeEntries - before, 1);
      });
      test('native idle skip preserves device ticks and notices changed RAM',
          () {
        final m = _Machine(Sh2Jit.create(
            native: native, compileThreshold: 1, idleGuards: true)!);
        final oracle = _Machine(null);
        addTearDown(m.dispose);
        for (final machine in [m, oracle]) {
          machine.load([0x6012, 0xaffd, 9, 0xffff]);
          machine.cpu.r[1] = _base + 0x1000;
          machine.bus.write32(_base + 0x1000, 7);
          machine.cpu.idleSkip = true;
          machine.cpu.onchip.frc = 0x2000;
          machine.cpu.run(64);
        }
        m.matches(oracle);
        expect(m.cpu.onchip.frc, oracle.cpu.onchip.frc);
        expect(m.cpu.clocks, 64);
        for (final machine in [m, oracle]) {
          machine.bus.write32(_base + 0x1000, 9);
          machine.cpu.run(128);
        }
        m.matches(oracle);
        expect(m.cpu.r[0], 9);
        expect(m.cpu.onchip.frc, oracle.cpu.onchip.frc);
      });
      test('native idle proof never skips adapter read callbacks', () {
        final m = _Machine(Sh2Jit.create(
            native: native, compileThreshold: 1, idleGuards: true)!);
        addTearDown(m.dispose);
        var reads = 0;
        m.jit!.addReadHelper((a, size) => a == 0x01001000 && size == 1,
            (_, __) {
          reads++;
          return 0;
        }, guardedLiterals: true);
        m.load([0xd101, 0x6010, 0xaffc, 9, 0x0100, 0x1000]);
        m.cpu.r[1] = 0x01001000;
        expect(m.jit!.run(_base, 64), (_base, 5));
        expect(m.jit!.idleCheckPc, _base);
        expect(reads, 1);
      });
      test(
          'MAC.L matches full and saturated accumulators including aliased operands',
          () {
        final m = _Machine(
            Sh2Jit.create(native: native, compileThreshold: 1, macLong: true)!);
        addTearDown(m.dispose);
        final oracle = _Machine(null);
        final rnd = Random(824);
        for (var i = 0; i < 180; i++) {
          final alias = i % 3 == 0;
          final op = alias ? 0x066f : 0x06af;
          final left = i == 0 ? 0x7fffffff : rnd.nextInt(0x100000000);
          final right = i == 0 ? 0x7fffffff : rnd.nextInt(0x100000000);
          final hi = rnd.nextInt(0x100000000), lo = rnd.nextInt(0x100000000);
          for (final machine in [oracle, m]) {
            machine.jit?.reset();
            machine.cpu.reset();
            machine.cpu.pc = _base;
            machine.load([op, 0xffff]);
            machine.cpu.r[6] = _base + 0x1000;
            machine.cpu.r[10] = _base + 0x2000;
            machine.cpu.sr = i.isEven ? 2 : 0;
            machine.cpu.mach = hi;
            machine.cpu.macl = lo;
            machine.bus.write32(_base + 0x1000, left);
            machine.bus.write32(_base + (alias ? 0x1004 : 0x2000), right);
            expect(machine.cpu.run(1), isTrue);
          }
          m.matches(oracle, memory: false);
          expect(m.jit!.compiledClocks, native ? 1 : 0);
        }
      });
      test('MAC.W matches the interpreter for saturation, MACH bit 0 and aliasing',
          () {
        final reference = _Machine(null);
        final jitted =
            _Machine(Sh2Jit.create(native: native, compileThreshold: 1, macWord: true)!);
        addTearDown(jitted.dispose);
        const words = [0, 1, 0x7fff, 0x8000, 0xffff, 0x100];
        const accumulators = [0, 0x7fffffff, 0x80000000, 0xffffffff, 0x7ffffff0];
        for (final instruction in [0x412f, 0x411f]) {
          // 0x411f reads consecutive words from one address register.
          final aliased = instruction == 0x411f;
          final rightAddress = aliased ? _base + 0x1002 : _base + 0x1100;
          for (final sat in [0, 2]) {
            for (final mach in [0, 1, 0xffffffff]) {
              for (final macl in accumulators) {
                for (final left in words) {
                  for (final right in words) {
                    jitted.jit!.reset();
                    for (final machine in [reference, jitted]) {
                      machine.load([instruction, 0xffff]);
                      machine.bus.write16(_base + 0x1000, left);
                      machine.bus.write16(rightAddress, right);
                      machine.cpu.pc = _base;
                      machine.cpu.clocks = 0;
                      machine.cpu.r[1] = _base + 0x1000;
                      machine.cpu.r[2] = aliased ? _base + 0x1000 : _base + 0x1100;
                      machine.cpu.sr = 0x3f0 | sat;
                      machine.cpu.mach = mach;
                      machine.cpu.macl = macl;
                    }
                    expect(jitted.cpu.run(1), isTrue);
                    expect(reference.cpu.run(1), isTrue);
                    jitted.matches(reference, memory: false);
                  }
                }
              }
            }
          }
        }
        // Without this, an interpreter fallback would also pass.
        if (native) expect(jitted.jit!.compiledClocks, greaterThan(0));
      });
      test('MAC.W read exit restores both increments and the accumulator', () {
        final m = _Machine(
            Sh2Jit.create(native: native, compileThreshold: 1, macWord: true)!);
        addTearDown(m.dispose);
        m.load([0x412f, 0xffff]);
        m.cpu.r[1] = _base + 0x1000;
        m.cpu.r[2] = _base + 0x100000;
        m.jit!.rt.unmapPages(_base + 0x100000, 4096);
        m.cpu.mach = 9;
        m.cpu.macl = 11;
        expect(m.jit!.run(_base, 1), isNull);
        expect((m.cpu.r[1], m.cpu.r[2]), (_base + 0x1000, _base + 0x100000));
        expect((m.cpu.mach, m.cpu.macl), (9, 11));
      });
      test('MAC.L second-read exit restores both increments and branch state',
          () {
        final m = _Machine(
            Sh2Jit.create(native: native, compileThreshold: 1, macLong: true)!);
        addTearDown(m.dispose);
        m.load([0x066f, 0xffff]);
        m.cpu.r[6] = _base + 0xffffc;
        m.jit!.rt.unmapPages(_base + 0x100000, 4096);
        m.bus.write32(_base + 0xffffc, 7);
        m.cpu.mach = 9;
        m.cpu.macl = 11;
        expect(m.jit!.run(_base, 4), isNull);
        expect(m.cpu.r[6], _base + 0xffffc);
        expect((m.cpu.mach, m.cpu.macl), (9, 11));
        m.jit!.reset();
        m.load([0xb002, 0x06af, 0xffff, 9, 0xffff, 9]);
        m.cpu.r[6] = _base + 0x1000;
        m.cpu.r[10] = 0xfffffe12;
        m.cpu.pr = 0x12345678;
        expect(m.jit!.run(_base, 8), isNull);
        expect(m.cpu.r[6], _base + 0x1000);
        expect(m.cpu.pr, 0x12345678);
      });
      test(
          'stable FTCSR bases avoid empty entries and reject other on-chip reads',
          () {
        final m = _Machine(Sh2Jit.create(native: native, compileThreshold: 2)!);
        final oracle = _Machine(null);
        addTearDown(m.dispose);
        for (final machine in [m, oracle]) {
          machine.load([0x6010, 0xaffd, 9, 0xffff]);
          machine.cpu.r[1] = 0xfffffe11;
          machine.cpu.onchip.ftcsr = 0x80;
          machine.cpu.run(24);
        }
        m.matches(oracle);
        final before = m.jit!.compiledClocks;
        for (final machine in [m, oracle]) {
          machine.cpu.onchip.ftcsr = 0x08;
          machine.cpu.run(32);
        }
        m.matches(oracle);
        expect(m.cpu.r[0], 8);
        expect(m.jit!.compiledClocks - before, native ? 8 : 0);
        for (final machine in [m, oracle]) {
          machine.cpu.r[1] = 0xfffffe12;
          machine.cpu.onchip.frc = 0x1234;
          machine.cpu.run(36);
        }
        m.matches(oracle);
        expect(m.cpu.r[0], 0x12);
      });
      test(
          'FTCSR reads use live context and retain CPU writes and unsafe fallback',
          () {
        // The signed PC-relative pointer is guarded before replacing the read.
        run([0x9104, 0x6010, 0xaffd, 9, 0xffff, 9, 0xfe11, 9], 18,
            initialize: (machine) {
          machine.cpu.onchip.ftcsr = 0x80;
        });
        expect(actual.cpu.r[0], 0xffffff80);
        for (final machine in [expected, actual]) {
          machine.cpu.pc = _base + 2;
          machine.cpu.onchip.ftcsr = 0x08;
          machine.cpu.run(19);
        }
        actual.matches(expected);
        expect(actual.cpu.r[0], 8);
        // CPU MMIO writes must refresh the next native read in the same run.
        run([0x2100, 0x6210, 0xaffc, 9], 60, initialize: (machine) {
          machine.cpu.onchip.ftcsr = 0x80;
          machine.cpu.r[1] = 0xfffffe11;
          machine.cpu.r[0] = 0;
        });
        expect(actual.cpu.r[2], 0);
      });
      test('store blocks chain across instruction limits past the budget', () {
        final m = _Machine(Sh2Jit.create(
            native: native, compileThreshold: 1, maxInstructions: 4)!);
        addTearDown(m.dispose);
        m.load([
          for (var i = 0; i < 5; i++) ...[0x7101, 0x2c12],
          0xffff
        ]);
        m.cpu.r[12] = _base + 0x1000;
        // Blocks of 4, 4 and 2 clocks: the last enters with one clock left.
        final result = m.jit!.run(_base, 9)!;
        expect(result, (_base + 20, 10));
        expect(m.cpu.r[1], 5);
        expect(m.bus.read32(_base + 0x1000), 5);
        expect(m.jit!.run(result.$1, 2), isNull);
      });
      test(
          'cold entries specialize only stable bases and safely reject changes',
          () {
        final m = _Machine(Sh2Jit.create(
            native: native, compileThreshold: 10, maxInstructions: 4)!);
        addTearDown(m.dispose);
        m.load([0x6142, 0x5241, 0x5342, 0x5543, 0xffff]);
        for (final machine in [expected, m]) {
          machine.load([0x6142, 0x5241, 0x5342, 0x5543, 0xffff]);
          for (var i = 0; i < 8; i++) {
            machine.bus.write32(_base + 0x1000 + 4 * i, 100 + i);
            machine.bus.write32(_base + 0x2000 + 4 * i, 200 + i);
          }
        }
        void pass(int address) {
          for (final machine in [expected, m]) {
            machine.cpu.pc = _base;
            machine.cpu.r[4] = address;
            expect(machine.cpu.run(machine.cpu.clocks + 4), isTrue);
          }
          m.matches(expected);
        }

        for (var i = 0; i < 9; i++) {
          pass(_base + 0x1000);
          expect(m.jit!.rt.contains(_base, 0), isFalse);
        }
        pass(_base + 0x1000);
        expect(m.jit!.rt.contains(_base, 0), isTrue);
        pass(_base + 0x2000);
        pass(_base + 0x2001);
        expect(m.cpu.r[1], 200);
        // An alias can replace the code after profiling; entry guards still win.
        m.bus.write16(_base + 0x100000, 0xe107);
        expected.bus.write16(_base, 0xe107);
        pass(_base + 0x1000);
        expect(m.cpu.r[1], 7);
        m.jit!.reset();
        expect(m.jit!.rt.contains(_base, 0), isFalse);
      });
      test(
          'linked profile misses invalidate the source block and refund precisely',
          () {
        final m = _Machine(Sh2Jit.create(
            native: native,
            compileThreshold: 2,
            maxInstructions: 1,
            stopOnNoStore: false)!);
        addTearDown(m.dispose);
        m.load([9, 0x6142, 0xffff, 9]);
        m.cpu.r[4] = _base + 0x1000;
        m.bus.write32(_base + 0x1000, 42);
        m.bus.write32(_base + 0x2000, 99);
        final jit = m.jit!;
        expect(jit.run(_base + 2, 1), isNull);
        expect(jit.run(_base + 2, 1), (_base + 4, 1));
        expect(jit.run(_base, 2), isNull);
        expect(jit.run(_base, 2), (_base + 4, 2));
        m.cpu.r[4] = _base + 0x2000;
        expect(jit.run(_base, 2), (_base + 2, 1));
        expect(m.cpu.r[1], 42);
        expect(jit.rt.contains(_base, 0), isTrue);
        expect(jit.rt.contains(_base + 2, 0), isFalse);
        expect(jit.run(_base + 2, 1), (_base + 4, 1));
        expect(m.cpu.r[1], 99);
        // Once unstable, the block remains generic across further pointer changes.
        m.cpu.r[4] = _base + 0x1000;
        expect(jit.run(_base + 2, 1), (_base + 4, 1));
        expect(jit.rt.contains(_base + 2, 0), isTrue);
        expect(m.cpu.r[1], 42);
      });
      test(
          'profile misses in delay slots replay the branch before link effects',
          () {
        final m = _Machine(Sh2Jit.create(
            native: native, compileThreshold: 2, stopOnNoStore: false)!);
        addTearDown(m.dispose);
        m.load([0xb002, 0x6142, 0xffff, 9, 0xffff, 9]);
        final jit = m.jit!;
        m.cpu.r[4] = _base + 0x1000;
        m.bus.write32(_base + 0x1000, 42);
        expect(jit.run(_base, 3), isNull);
        expect(jit.run(_base, 3), (_base + 8, 3));
        m.cpu.pr = 0x1234;
        m.cpu.r[4] = _base + 0x2000;
        expect(jit.run(_base, 3), isNull);
        expect(m.cpu.pr, 0x1234);
        expect(m.cpu.r[1], 42);
        expect(jit.rt.ctx[JitCtx.budget], 3);
        expect(jit.rt.exitPc, _base);
      });
      test('a positive budget runs a whole block and keeps code guards', () {
        final m = _Machine(Sh2Jit.create(
            native: native, compileThreshold: 1, maxInstructions: 4)!);
        addTearDown(m.dispose);
        m.load([0x7101, 0x7101, 0x7101, 0x7101, 0xffff, 9]);
        final jit = m.jit!;
        expect(jit.run(_base, 4), (_base + 8, 4));
        expect(jit.run(_base, 1), (_base + 8, 4));
        expect(m.cpu.r[1], 8);
        m.bus.write16(_base, 0xe107);
        expect(jit.run(_base, 1), (_base + 8, 4));
        expect(m.cpu.r[1], 10);
        jit.rt.clear();
        expect(jit.rt.blockCost(_base, 0), isNull);
        expect(jit.run(_base, 4), (_base + 8, 4));
        expect(m.cpu.r[1], 10);
      });
      test('random integer operations, flags and shared state match CPU', () {
        final random = Random(43);
        const ops = [
          0x6003,
          0x6007,
          0x6008,
          0x6009,
          0x600a,
          0x600b,
          0x600c,
          0x600d,
          0x600e,
          0x600f,
          0x2008,
          0x2009,
          0x200a,
          0x200b,
          0x200d,
          0x200e,
          0x200f,
          0x2007,
          0x3000,
          0x3002,
          0x3003,
          0x3004,
          0x3006,
          0x3007,
          0x3008,
          0x300a,
          0x300b,
          0x300c,
          0x300e,
          0x300f,
          0x0007
        ];
        final code = [
          for (var i = 0; i < 160; i++)
            ops[random.nextInt(ops.length)] |
                (random.nextInt(8) << 8) |
                (random.nextInt(8) << 4),
          0xaffe,
          0x0009
        ];
        final initial = List.generate(16, (_) => random.nextInt(0x100000000));
        run(code, 800, initialize: (m) {
          m.cpu.r.setAll(0, initial);
          m.cpu.sr = 0x3f3;
        });
        expect(actual.jit!.rt.contains(_base, 0), isTrue);
        if (native) expect(actual.jit!.compiledClocks, greaterThan(0));
      });
      test('shifts, rotates, extensions and T updates agree', () {
        const kinds = [
          0,
          0x20,
          1,
          0x21,
          4,
          5,
          0x24,
          0x25,
          8,
          9,
          0x18,
          0x19,
          0x28,
          0x29,
          0x10,
          0x11,
          0x15
        ];
        run([
          for (final kind in kinds) ...[0x4000 | kind, 0x0129],
          0xaffe,
          9
        ], 300, initialize: (m) => m.cpu.r[0] = 0x80000001);
      });
      test('big endian loads, stores and addressing updates agree', () {
        run([
          0x61c0,
          0x62c1,
          0x63c2,
          0x24c6,
          0x65c4,
          0x66c5,
          0x67c6,
          0x1c12,
          0x58c2,
          0xaffe,
          9
        ], 70, initialize: (m) {
          m.cpu.r[12] = _base + 0x1000;
          m.cpu.r[4] = _base + 0x1100;
          m.bus.write32(_base + 0x1000, 0x80abcdef);
          m.bus.write32(_base + 0x1004, 0xfedc1234);
        });
      });
      test('branch conditions and register targets use pre-slot operands', () {
        run([
          0xe001,
          0x8801,
          0x8d01,
          0xe000,
          0xe1ff,
          0xe202,
          0x0008,
          0x8f01,
          0x0018,
          0xe3ff,
          0xaffe,
          9
        ], 60);
        for (final m in [expected, actual]) {
          m.cpu.reset();
          m.cpu.pc = _base;
          m.cpu.pr = _base + 8;
          m.load([0x000b, 0x402a, 0xe5ff, 0x0009, 0xaffe, 9]);
          m.cpu.r[0] = _base + 16;
          expect(m.cpu.run(100), isTrue);
        }
        expect(expected.cpu.run(actual.cpu.clocks), isTrue);
        actual.matches(expected);
      });
      test('delay-slot device exit replays link and register state precisely',
          () {
        run([0xb002, 0x61c2, 0xe2ff, 0x0009, 0xaffe, 9], 60, initialize: (m) {
          m.cpu.r[12] = 0x01001000;
          m.bus.write32(0x1000, 0x87654321);
        });
        expect(actual.cpu.pr, _base + 4);
        expect(actual.cpu.r[1], 0x87654321);
      });
      test('small budgets preserve branch and delay-slot boundaries', () {
        for (final m in [expected, actual]) {
          m.load([0x7001, 0x8803, 0x8bfc, 0xaffe, 9]);
        }
        for (var target = 1; target < 80; target++) {
          expect(actual.cpu.run(target), isTrue);
          expect(expected.cpu.run(max(target, actual.cpu.clocks)), isTrue);
          actual.matches(expected, memory: false);
        }
        actual.matches(expected);
      });
      test('stores through RAM mirrors cannot alter upcoming guarded code', () {
        run([0x2c11, 0x0009, 0xe301, 0xaffe, 9], 40, initialize: (m) {
          m.cpu.r[12] = _base + 0x100004;
          m.cpu.r[1] = 0xe307;
        });
        expect(actual.cpu.r[3], 7);
        for (final m in [expected, actual]) {
          m.bus.write16(_base + 4, 0xe309);
          m.cpu.pc = _base + 4;
        }
        actual.cpu.run(80);
        expected.cpu.run(max(80, actual.cpu.clocks));
        actual.matches(expected);
        expect(actual.cpu.r[3], 9);
      });
      test('unsupported arithmetic resumes the CPU with complete live state',
          () {
        run([0x7101, 0x3125, 0x321d, 0x0019, 0xaffa, 9], 200, initialize: (m) {
          m.cpu.r[1] = 0xfffffffe;
          m.cpu.r[2] = 0x80000001;
          m.cpu.sr = 0x3f3;
        });
      });
      test('idle-loop skipping keeps the same boundary state', () {
        for (final m in [expected, actual]) {
          m.cpu.idleSkip = true;
          m.load([0x0009, 0xaffd, 0x0009]);
        }
        for (final target in [32, 64, 100, 200]) {
          expect(actual.cpu.run(target), isTrue);
          expect(expected.cpu.run(max(target, actual.cpu.clocks)), isTrue);
          actual.matches(expected);
        }
      });
      test('reset restores RAM write mappings before code pages become data',
          () {
        run([0x7001, 0xaffd, 9], 20);
        final page = _base >>> actual.jit!.rt.pageShift;
        expect(actual.jit!.rt.writePages[page], isNull);
        expect(
            actual.jit!.rt
                .writePages[page + (0x100000 >>> actual.jit!.rt.pageShift)],
            isNull);
        for (final m in [expected, actual]) {
          m.cpu.reset();
          m.cpu.pc = _base + 0x1000;
          m.cpu.r[12] = _base;
          final code = [0xe12a, 0x2c12, 0xaffe, 9];
          for (var i = 0; i < code.length; i++) {
            m.bus.write16(_base + 0x1000 + i * 2, code[i]);
          }
          expect(m.cpu.run(40), isTrue);
        }
        expect(expected.cpu.run(actual.cpu.clocks), isTrue);
        actual.matches(expected);
        expect(actual.bus.read32(_base), 42);
        expect(actual.jit!.rt.writePages[page], isNotNull);
      });
      test('pending interrupts and debugger steps use CPU execution', () {
        for (final m in [expected, actual]) {
          m.load([0x7001, 0xaffe, 9]);
          m.cpu.sr = 0xf0;
          expect(m.cpu.step(), isTrue);
          m.bus.write32(11 * 4, _base + 2);
          m.cpu.r[15] = _base + 0x2000;
          m.cpu.nmi();
          expect(m.cpu.run(20), isTrue);
        }
        expect(expected.cpu.run(actual.cpu.clocks), isTrue);
        actual.matches(expected);
      });
    }, skip: native && !supported ? 'No native backend' : false);
  }
}
