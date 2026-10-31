import 'dart:math';
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ps/bus.dart';
import 'package:fnesemu_core/src/core/ps/jit/ps_jit.dart';
import 'package:fnesemu_core/src/core/ps/r3000/r3000.dart';
import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

const _code = 0x80010000;
const _data = 0x80100000; // 8KiB of data
const _vector = 0x80000080;

/// reserved base registers of the generated programs
const _rData = 28, _rUncached = 27, _rRom = 26, _rScratch = 25;
const _rJump = 24, _rCount = 23;

final class _Machine {
  final Bus bus;
  final R3000 cpu;
  final PsJit? jit;

  _Machine._(this.bus, this.cpu, this.jit);

  factory _Machine.interpreter() {
    final bus = Bus();
    return _Machine._(bus, R3000(bus), null);
  }

  factory _Machine.jit(PsJit jit) {
    final bus = Bus(mem: jit.ram, rom: jit.rom, scratchPad: jit.scratchPad);
    final cpu = R3000(bus, regs: jit.regs);
    jit.attach(cpu, bus);
    return _Machine._(bus, cpu, jit);
  }

  void load(List<int> program, Uint8List rom, Uint8List data) {
    jit?.reset();
    cpu.reset();
    bus.rom.setAll(0, rom);
    bus.mem.fillRange(0, bus.mem.length, 0);
    bus.mem.setAll(_data & 0x1fffff, data);
    for (final (i, inst) in program.indexed) {
      bus.write32(_code + 4 * i, inst);
    }
    // the exception handler jumps to the end
    bus.write32(_vector, _j(_code + 4 * (program.length - 2)));
    bus.write32(_vector + 4, 0);
    bus.useScratchPad = true;
    cpu.pc = _code;
    cpu.nextPc = _code + 4;
  }

  /// runs until the final self loop
  void run(int end, Random rnd) {
    final jit = this.jit;
    for (int n = 0; n < 2000000 && cpu.pc != end; n++) {
      if (jit == null) {
        cpu.step();
      } else {
        jit.run(cpu.clocks + 1 + rnd.nextInt(400));
      }
    }
    expect(cpu.pc, end, reason: 'the program did not finish');
    // a load in the delay slot of a branch to the end lands in the loop
    while (cpu.nextDelayReg != 0 || cpu.pc != end) {
      cpu.step();
    }
  }

  List<int> get state => [
        ...cpu.r,
        cpu.hi,
        cpu.lo,
        cpu.sr,
        cpu.cause,
        cpu.epc,
        for (int i = 0; i < 32; i++) cpu.cop2.readReg(i),
        for (int i = 0; i < 32; i++) cpu.cop2.readCtrl(i),
      ];
}

int _r(int op, int rs, int rt, int rd, int sa, int funct) =>
    op << 26 | rs << 21 | rt << 16 | rd << 11 | sa << 6 | funct;
int _i(int op, int rs, int rt, int imm) =>
    op << 26 | rs << 21 | rt << 16 | (imm & 0xffff);
int _j(int target) => 0x02 << 26 | (target >> 2) & 0x3ffffff;

/// Generates programs of random instructions over the data areas, with
/// branches, loads in delay slots, bounded loops and overflows.
final class _Generator {
  final Random rnd;
  final out = <int>[];

  /// instructions a branch must not land on
  final _noTarget = <int>{};

  _Generator(this.rnd);

  // a few registers, so that instructions depend on each other
  int get _dst => [1, 2, 3, 4, 5, 31][rnd.nextInt(6)];
  int get _src => rnd.nextInt(4) == 0 ? rnd.nextInt(32) : rnd.nextInt(6);

  int _alu() {
    final rs = _src, rt = _src, rd = _dst;
    final imm =
        [0, 1, -1, 0x7fff, -0x8000, rnd.nextInt(0x10000)][rnd.nextInt(6)];
    return switch (rnd.nextInt(30)) {
      0 => _r(0, 0, rt, rd, rnd.nextInt(32), 0x00), // sll
      1 => _r(0, 0, rt, rd, rnd.nextInt(32), 0x02), // srl
      2 => _r(0, 0, rt, rd, rnd.nextInt(32), 0x03), // sra
      3 => _r(0, rs, rt, rd, 0, 0x04), // sllv
      4 => _r(0, rs, rt, rd, 0, 0x06),
      5 => _r(0, rs, rt, rd, 0, 0x07),
      6 => _r(0, 0, 0, rd, 0, 0x10), // mfhi
      7 => _r(0, rs, 0, 0, 0, 0x11), // mthi
      8 => _r(0, 0, 0, rd, 0, 0x12), // mflo
      9 => _r(0, rs, 0, 0, 0, 0x13),
      10 => _r(0, rs, rt, 0, 0, 0x18), // mult
      11 => _r(0, rs, rt, 0, 0, 0x19),
      12 => _r(0, rs, rt, 0, 0, 0x1a), // div
      13 => _r(0, rs, rt, 0, 0, 0x1b),
      14 => _r(0, rs, rt, rd, 0, 0x20 + rnd.nextInt(8)), // add .. nor
      15 => _r(0, rs, rt, rd, 0, 0x2a + rnd.nextInt(2)), // slt, sltu
      16 => _i(0x08 + rnd.nextInt(8), rs, rd, imm), // addi .. lui
      17 => _i(0x09, rs, rd, imm),
      18 => 0, // nop
      19 => _cop2(),
      _ => _mem(),
    };
  }

  int _cop2() {
    const cmds = [0x01, 0x06, 0x0c, 0x10, 0x12, 0x28, 0x2d, 0x3d];
    return switch (rnd.nextInt(5)) {
      0 => _r(0x12, 0x00, _dst, rnd.nextInt(32), 0, 0), // mfc2
      1 => _r(0x12, 0x02, _dst, rnd.nextInt(32), 0, 0), // cfc2
      2 => _r(0x12, 0x04, _src, rnd.nextInt(32), 0, 0), // mtc2
      3 => _r(0x12, 0x06, _src, rnd.nextInt(32), 0, 0), // ctc2
      _ => 0x4a000000 | rnd.nextInt(0x80000) << 6 | cmds[rnd.nextInt(8)],
    };
  }

  int _mem() {
    final base = [_rData, _rData, _rUncached, _rRom, _rScratch][rnd.nextInt(5)];
    // the scratchpad offsets stay in its 1KiB
    final off = base == _rScratch
        ? rnd.nextInt(0x3fc) - 0x200
        : rnd.nextInt(0x800) - 0x400;
    const loads = [0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x32];
    const stores = [0x28, 0x29, 0x2a, 0x2b, 0x2e, 0x3a];
    if (base == _rRom || rnd.nextBool()) {
      final op = loads[rnd.nextInt(loads.length)];
      return _i(op, base, op == 0x32 ? rnd.nextInt(32) : _dst, off);
    }
    final op = stores[rnd.nextInt(stores.length)];
    return _i(op, base, op == 0x3a ? rnd.nextInt(32) : _src, off);
  }

  void _addr(int reg, int value) {
    out.add(_i(0x0f, 0, reg, value >> 16));
    out.add(_i(0x0d, reg, reg, value));
  }

  List<int> program(int length) {
    _addr(_rData, _data + 0x1000);
    _addr(_rUncached, (_data | 0x20000000) + 0x1800);
    _addr(_rRom, 0xbfc00800);
    _addr(_rScratch, 0x1f800200);
    final fixups = <(int, int)>[]; // branch index, target index
    while (out.length < length) {
      switch (rnd.nextInt(12)) {
        case 0: // a forward branch
          final at = out.length;
          final rs = _src, rt = _src;
          out.add(switch (rnd.nextInt(7)) {
            0 => _i(0x04, rs, rt, 0),
            1 => _i(0x05, rs, rt, 0),
            2 => _i(0x06, rs, 0, 0),
            3 => _i(0x07, rs, 0, 0),
            4 => _i(0x01, rs, [0, 1, 0x10, 0x11][rnd.nextInt(4)], 0),
            5 => 0x03 << 26, // jal
            _ => 0x02 << 26, // j
          });
          out.add(_alu()); // delay slot
          fixups.add((at, at + 2 + rnd.nextInt(6)));
        case 1: // a bounded loop
          out.add(_i(0x09, 0, _rCount, 1 + rnd.nextInt(20)));
          final start = out.length;
          for (int k = rnd.nextInt(6); k >= 0; k--) {
            out.add(_alu());
          }
          // bgtz, so that a branch into the body does not loop long
          out.add(_i(0x09, _rCount, _rCount, -1));
          out.add(_i(0x07, _rCount, 0, start - out.length - 1));
          out.add(_alu());
        case 2: // an indirect call to the next instruction pair
          final target = _code + 4 * (out.length + 4);
          _addr(_rJump, target);
          _noTarget.addAll([out.length - 1, out.length]);
          out.add(_r(0, _rJump, 0, rnd.nextBool() ? 31 : 0, 0, 0x09)); // jalr
          out.add(_alu());
        case 3: // add, addi or sub, which may overflow
          out.add(rnd.nextBool()
              ? _r(0, _src, _src, _dst, 0, rnd.nextBool() ? 0x20 : 0x22)
              : _i(0x08, _src, _dst, rnd.nextInt(0x10000)));
        default:
          out.add(_alu());
      }
    }
    // the end: a self loop after nops, which land the last load
    out.addAll([0, 0]);
    final end = out.length;
    out.add(_j(_code + 4 * end));
    out.add(0);
    for (final (at, target) in fixups) {
      var t = target > end ? end : target;
      while (_noTarget.contains(t)) {
        t++;
      }
      final op = out[at] >>> 26;
      out[at] = op == 0x02 || op == 0x03
          ? op << 26 | ((_code + 4 * t) >> 2) & 0x3ffffff
          : out[at] & 0xffff0000 | (t - at - 1) & 0xffff;
    }
    return out;
  }
}

void main() {
  test('CPU profiling preserves load delays, registers, memory and clocks', () {
    final expected = _Machine.interpreter();
    final actual = _Machine.jit(PsJit.create(native: false)!);
    addTearDown(actual.jit!.dispose);
    for (final machine in [expected, actual]) {
      machine.load([
        _i(9, 0, 1, 42),
        _i(0x2b, 28, 1, 0),
        _i(0x23, 28, 2, 0),
        0,
        _j(_code + 16),
        0
      ], Uint8List(0x80000), Uint8List(8192));
      machine.cpu.r[28] = _data;
    }
    final stats = actual.jit!.diagnostics.enableExecutionStats();
    for (var i = 0; i < 4; i++) {
      actual.cpu.step();
      expected.cpu.step();
    }
    expect(actual.state, expected.state);
    expect(actual.cpu.pc, expected.cpu.pc);
    expect(actual.cpu.clocks, expected.cpu.clocks);
    expect(actual.bus.mem, expected.bus.mem);
    expect(stats.cpuClocks, actual.cpu.clocks);
    expect(stats.cpuDispatches, 4);
    expect((stats.report()['memory'] as List).map((e) => e['kind']),
        containsAll(['fetch', 'read', 'write']));
    actual.jit!.diagnostics.disableExecutionStats();
    expect(actual.cpu.executionStats, isNull);
  });
  for (final native in [false, true]) {
    final name = native ? 'native' : 'interpreted';
    test('$name clock counter excludes CPU and IR interpreter execution', () {
      final jit = PsJit.create(native: native, compileThreshold: 1);
      if (jit == null) {
        markTestSkipped('no native recompiler on this host');
        return;
      }
      addTearDown(jit.dispose);
      expect(jit.native, native);
      final m = _Machine.jit(jit);
      m.load([_i(0x09, 1, 1, 1), _j(_code), 0], Uint8List(512 * 1024),
          Uint8List(0));
      jit.run(100);
      expect(jit.compiledClocks, native ? m.cpu.clocks : 0);
      final compiled = jit.compiledClocks;
      final clocks = m.cpu.clocks;
      m.cpu.sr |= 0x10000; // Cache isolation forces the CPU interpreter.
      jit.run(m.cpu.clocks + 20);
      expect(m.cpu.clocks, greaterThan(clocks));
      expect(jit.compiledClocks, compiled);
      m.cpu.sr &= ~0x10000;
      jit.run(m.cpu.clocks + 100);
      expect(jit.compiledClocks, native ? greaterThan(compiled) : equals(0));
      jit.reset();
      expect(jit.compiledClocks, 0);
    });

    test('$name cold CPU blocks do not count as compiled execution', () {
      final jit = PsJit.create(native: native, compileThreshold: 1000);
      if (jit == null) {
        markTestSkipped('no native recompiler on this host');
        return;
      }
      addTearDown(jit.dispose);
      final m = _Machine.jit(jit);
      m.load([_j(_code), 0], Uint8List(512 * 1024), Uint8List(0));
      jit.run(100);
      expect(m.cpu.clocks, greaterThan(100));
      expect(jit.compiledClocks, 0);
    });

    // 1 translates every block; the default interprets cold blocks first
    for (final threshold in [1, null]) {
      test(
          '$name blocks run random programs like the interpreter'
          '${threshold == null ? ' after warming up' : ''}', () {
        if (identical(0, 0.0)) {
          // R3000.mult and multu lose the upper bits with the numbers of JS
          markTestSkipped('the interpreter multiplies inexactly on dart2js');
          return;
        }
        final jit = PsJit.create(native: native, compileThreshold: threshold);
        if (jit == null) {
          markTestSkipped('no native recompiler on this host');
          return;
        }
        addTearDown(jit.dispose);
        final a = _Machine.interpreter(), b = _Machine.jit(jit);
        final rnd = Random(7);
        for (int n = 0; n < 300; n++) {
          final program = _Generator(rnd).program(40 + rnd.nextInt(200));
          final rom = Uint8List.fromList(
              List.generate(512 * 1024, (i) => (i * 0x9e3779b1) >> 13));
          final data = Uint8List.fromList(
              List.generate(0x2000, (_) => rnd.nextInt(256)));
          final end = _code + 4 * (program.length - 2);
          for (final m in [a, b]) {
            m.load(program, rom, data);
            m.run(end, rnd);
          }
          expect(b.state, a.state, reason: 'program $n');
          expect(
              b.bus.mem.sublist(_data & 0x1fffff, (_data & 0x1fffff) + 0x2000),
              a.bus.mem.sublist(_data & 0x1fffff, (_data & 0x1fffff) + 0x2000),
              reason: 'program $n');
          expect(b.bus.scratchPad.sublist(0, 1024), a.bus.scratchPad,
              reason: 'program $n');
        }
      });
    }

    test('$name blocks keep the load delay of the interpreter', () {
      final jit = PsJit.create(native: native, compileThreshold: 1);
      if (jit == null) {
        markTestSkipped('no native recompiler on this host');
        return;
      }
      addTearDown(jit.dispose);
      final a = _Machine.interpreter(), b = _Machine.jit(jit);
      final lw5 = _i(0x23, _rData, 5, 0), lw5b = _i(0x23, _rData, 5, 4);
      final use = _r(0, 5, 0, 6, 0, 0x21); // addu r6, r5, r0
      final cases = [
        [lw5, use], // the old value
        [lw5, lw5b, use], // the second load cancels the first
        [lw5, _i(0x22, _rData, 5, 9), use], // lwl merges the loaded value
        [lw5, _i(0x26, _rData, 5, 10), use], // lwr
        [lw5, _r(0x12, 0, 5, 3, 0, 0), use], // mfc2 cancels
        // a load in a delay slot lands in the next block
        [_i(0x05, 0, _rData, 1), lw5, use, use],
        [_i(0x04, 0, 0, 1), lw5b, use, use],
        [_i(0x04, 0, 0, 1), lw5, lw5b, use, use],
      ];
      for (final (n, c) in cases.indexed) {
        final program = [
          _i(0x0f, 0, _rData, (_data + 0x1000) >> 16),
          _i(0x0d, _rData, _rData, _data + 0x1000),
          _i(0x09, 0, 5, 0x55),
          ...c,
          0,
          0,
          _j(_code + 4 * (c.length + 5)),
          0,
        ];
        final data =
            Uint8List.fromList(List.generate(0x2000, (i) => i * 37 + 11));
        final end = _code + 4 * (c.length + 5);
        for (final m in [a, b]) {
          m.load(program, Uint8List(512 * 1024), data);
          m.run(end, Random(n));
        }
        expect(b.state, a.state, reason: 'case $n');
      }
    });

    test('$name COP0 reads preserve load delays and branch slots', () {
      final jit = PsJit.create(native: native, compileThreshold: 1);
      if (jit == null) {
        markTestSkipped('no native recompiler on this host');
        return;
      }
      addTearDown(jit.dispose);
      final a = _Machine.interpreter(), b = _Machine.jit(jit);
      for (final reg in [0, 6, 8, 12, 13, 14, 15]) {
        final program = [
          _i(0x09, 0, 5, 0x55),
          _r(0x10, 0, 5, reg, 0, 0),
          _r(0, 5, 0, 6, 0, 0x21),
          _r(0, 5, 0, 7, 0, 0x21),
          _i(0x04, 0, 0, 1),
          _r(0x10, 0, 8, reg, 0, 0),
          _r(0, 8, 0, 9, 0, 0x21),
          _r(0, 8, 0, 10, 0, 0x21),
          _j(_code + 4 * 8),
          0,
        ];
        for (final m in [a, b]) {
          m.load(program, Uint8List(512 * 1024), Uint8List(0));
          m.cpu.tar = 0x81234560;
          m.cpu.badvaddr = 0x9f800400;
          m.cpu.sr = 0x40000000;
          m.cpu.cause = 0x300;
          m.cpu.epc = 0x80123458;
          m.run(_code + 4 * 8, Random(reg));
          expect(m.cpu.r[6], 0x55);
          expect(m.cpu.r[9], 0);
          expect(m.cpu.r[7], m.cpu.readCop0(reg));
          expect(m.cpu.r[10], m.cpu.readCop0(reg));
        }
        expect(b.state, a.state, reason: 'COP0 register $reg');
      }
    });

    test('$name compiled low vectors retain BIOS hooks', () {
      final jit = PsJit.create(native: native, compileThreshold: 1);
      if (jit == null) {
        markTestSkipped('no native recompiler on this host');
        return;
      }
      addTearDown(jit.dispose);
      final m = _Machine.jit(jit);
      final end = _code + 4 * 4;
      m.load([
        _i(0x09, 0, 9, 0x3d), // B0 putchar
        _i(0x09, 0, 4, 0x58),
        _j(0x80000080),
        0,
        _j(end),
        0,
      ], Uint8List(512 * 1024), Uint8List(0));
      m.bus.write32(0x80000080, _j(0x800000b0));
      m.bus.write32(0x80000084, 0);
      m.bus.write32(0x800000b0, _j(end));
      m.bus.write32(0x800000b4, 0);
      m.run(end, Random(1));
      expect(jit.rt.contains(0x80000080, 0), isTrue);
      expect(m.cpu.console.toString(), 'X');
    });

    test('$name scratchpad loads and stores stay in compiled blocks', () {
      final jit = PsJit.create(native: native, compileThreshold: 1);
      if (jit == null) {
        markTestSkipped('no native recompiler on this host');
        return;
      }
      addTearDown(jit.dispose);
      final m = _Machine.jit(jit);
      final program = [
        _i(0x0f, 0, 2, 0x1f80),
        _i(0x09, 0, 3, 0x1234),
        _i(0x2b, 2, 3, 0x3fc),
        _i(0x23, 2, 4, 0x3fc),
        0,
        _i(0x0f, 0, 2, 0x9f80),
        _i(0x25, 2, 5, 0x3fc),
        0,
        _i(0x24, 2, 6, 0x3fd),
        0,
        _j(_code + 4 * 10),
        0,
      ];
      m.load(program, Uint8List(512 * 1024), Uint8List(0));
      jit.rt.ctx[JitCtx.faultAddr] = 0xdeadbeef;
      jit.run(m.cpu.clocks + 200);
      expect(m.cpu.r[4], 0x1234);
      expect(m.cpu.r[5], 0x1234);
      expect(m.cpu.r[6], 0x12);
      expect(jit.rt.ctx[JitCtx.faultAddr], 0xdeadbeef,
          reason:
              'scratchpad accesses must not leave through memory side exits');
    });

    test('$name scratchpad excludes invalid virtual aliases', () {
      final jit = PsJit.create(native: native, compileThreshold: 1);
      if (jit == null) {
        markTestSkipped('no native recompiler on this host');
        return;
      }
      addTearDown(jit.dispose);
      final m = _Machine.jit(jit);
      for (final high in [0x3f80, 0x5f80, 0x7f80, 0xbf80, 0xdf80, 0xff80]) {
        m.load([
          _i(0x0f, 0, 2, high),
          _i(0x09, 0, 3, 0x1234),
          _i(0x2b, 2, 3, 0),
          _i(0x23, 2, 4, 0),
          _i(0x25, 2, 5, 0),
          _i(0x24, 2, 6, 0),
          0,
          _j(_code + 4 * 7),
          0,
        ], Uint8List(512 * 1024), Uint8List(0));
        m.bus.write32(0x1f800000, 0x5678);
        m.run(_code + 4 * 7, Random(1));
        expect(m.cpu.r.sublist(4, 7), [0, 0, 0], reason: 'alias $high');
        expect(m.bus.read32(0x1f800000), 0x5678);
      }
    });

    test('$name scratchpad mapping follows cache control changes', () {
      final jit = PsJit.create(native: native, compileThreshold: 1);
      if (jit == null) {
        markTestSkipped('no native recompiler on this host');
        return;
      }
      addTearDown(jit.dispose);
      final m = _Machine.jit(jit);
      final program = [
        _i(0x0f, 0, 2, 0x1f80),
        _i(0x09, 0, 3, 0x1234),
        _i(0x2b, 2, 3, 0),
        _i(0x0f, 0, 8, 0xfffe),
        _i(0x2b, 8, 0, 0x130),
        _i(0x23, 2, 4, 0),
        0,
        _i(0x2b, 2, 0, 0),
        _i(0x09, 0, 9, 0x88),
        _i(0x2b, 8, 9, 0x130),
        _i(0x23, 2, 5, 0),
        0,
        _j(_code + 4 * 12),
        0,
      ];
      m.load(program, Uint8List(512 * 1024), Uint8List(0));
      m.run(_code + 4 * 12, Random(1));
      expect(m.cpu.r[4], 0xffffffff);
      expect(m.cpu.r[5], 0x1234);
      expect(m.bus.read32(0x1f800000), 0x1234);
    });

    test('$name blocks respect unmapped memory ranges', () {
      final jit = PsJit.create(native: native, compileThreshold: 1);
      if (jit == null) {
        markTestSkipped('no native recompiler on this host');
        return;
      }
      addTearDown(jit.dispose);
      final m = _Machine.jit(jit);
      final program = [
        _i(0x0f, 0, 2, 0x1f80),
        _i(0x0d, 2, 2, 0x0400),
        _i(0x09, 0, 3, 0x1234),
        _i(0x2b, 2, 3, 0),
        _i(0x23, 2, 4, 0),
        _i(0x0f, 0, 5, 0xbf80),
        _i(0x2b, 5, 3, 0),
        _i(0x23, 5, 6, 0),
        _i(0x0f, 0, 7, 0x0080),
        _i(0x23, 7, 8, 0),
        0,
        0,
        _j(_code + 4 * 12),
        0,
      ];
      m.load(program, Uint8List(512 * 1024), Uint8List(0));
      m.bus.write32(0x1f800000, 0x5678);
      m.bus.write32(0, 0x12345678);
      m.run(_code + 4 * 12, Random(1));
      expect(m.cpu.r[4], 0);
      expect(m.cpu.r[6], 0);
      expect(m.cpu.r[8], 0);
      expect(m.bus.read32(0x1f800000), 0x5678);
    });

    test('$name blocks see code written by the program', () {
      final jit = PsJit.create(native: native, compileThreshold: 1);
      if (jit == null) {
        markTestSkipped('no native recompiler on this host');
        return;
      }
      addTearDown(jit.dispose);
      final m = _Machine.jit(jit);
      // the loop rewrites `addiu r1, r1, 1` at 0x80010010 to add 2, then 3,
      // after the block of the loop is translated
      final program = [
        _i(0x09, 0, 3, 3), // addiu r3, r0, 3
        _i(0x0f, 0, 4, _code >> 16), // lui r4, code
        0,
        0,
        _i(0x09, 1, 1, 1), // 0x10: addiu r1, r1, 1
        _i(0x09, 3, 3, -1), // addiu r3, r3, -1
        _i(0x2b, 4, 6, 0x10), // sw r6, 0x10(r4)
        _i(0x05, 3, 0, -4), // bne r3, r0, 0x10
        _i(0x09, 6, 6, 1), // addiu r6, r6, 1
        _j(_code + 4 * 9),
        0,
      ];
      m.load(program, Uint8List(512 * 1024), Uint8List(0));
      m.cpu.r[6] = _i(0x09, 1, 1, 2); // addiu r1, r1, 2
      m.run(_code + 4 * 9, Random(1));
      expect(m.cpu.r[1], 1 + 2 + 3);

      // code loaded by the host, as by a DMA, replaces the blocks too
      m.bus.write32(_code + 0x10, _i(0x09, 1, 1, 10));
      m.cpu.r[1] = 0;
      m.cpu.pc = _code;
      m.cpu.nextPc = _code + 4;
      m.run(_code + 4 * 9, Random(1));
      expect(m.cpu.r[1], 10 + 5 + 6);
    });
  }
}
