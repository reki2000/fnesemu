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
    }, skip: native && !supported ? 'No native backend' : false);
  }
}
