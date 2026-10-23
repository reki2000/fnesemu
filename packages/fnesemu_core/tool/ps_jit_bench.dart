// compares the R3000 interpreter with the recompiler on a synthetic loop of
// ALU, load/store and branch instructions, run in slices of clocks as the
// device events of the ps core slice them.
//
// usage: dart compile exe tool/ps_jit_bench.dart -o /tmp/ps-jit-bench
//        /tmp/ps-jit-bench [-s SLICE]...
import 'package:fnesemu_core/src/core/ps/bus.dart';
import 'package:fnesemu_core/src/core/ps/jit/ps_jit.dart';
import 'package:fnesemu_core/src/core/ps/r3000/r3000.dart';

int _r(int rs, int rt, int rd, int funct) =>
    rs << 21 | rt << 16 | rd << 11 | funct;
int _i(int op, int rs, int rt, int imm) =>
    op << 26 | rs << 21 | rt << 16 | (imm & 0xffff);

const _code = 0x80010000;

/// a checksum over a 4KiB buffer, written to a second buffer, [_outer]
/// times; it ends in a self loop at [_end]
const _outer = int.fromEnvironment('BENCH_LOOPS', defaultValue: 3000);
final _program = [
  _i(0x0f, 0, 8, 0x8010), // lui t0, 0x8010
  _i(0x09, 0, 16, _outer), // addiu s0, r0, outer
  // outer:
  _i(0x09, 8, 9, 0), // addiu t1, t0, 0
  _i(0x09, 0, 10, 1024), // addiu t2, r0, 1024
  // inner:
  _i(0x23, 9, 11, 0), // lw t3, 0(t1)
  _i(0x09, 10, 10, -1), // addiu t2, t2, -1
  _r(11, 12, 12, 0x21), // addu t4, t4, t3
  _r(12, 0, 13, 0x00) | 3 << 6, // sll t5, t4, 3
  _r(13, 12, 12, 0x26), // xor t4, t4, t5
  _i(0x2b, 9, 12, 0x1000), // sw t4, 0x1000(t1)
  _i(0x05, 10, 0, -7), // bne t2, r0, inner
  _i(0x09, 9, 9, 4), // addiu t1, t1, 4
  _i(0x09, 16, 16, -1), // addiu s0, s0, -1
  _i(0x05, 16, 0, -12), // bne s0, r0, outer
  0,
  0x08000000 | (_end >> 2) & 0x3ffffff, // end: j end
  0,
];
const _end = _code + 4 * 15;

void main(List<String> args) {
  final slices = [
    for (int i = 0; i < args.length; i++)
      if (args[i] == '-s') int.parse(args[++i])
  ];
  if (slices.isEmpty) slices.addAll([24, 100, 1000, 100000]);

  void load(Bus bus, R3000 cpu) {
    cpu.reset();
    for (final (i, inst) in _program.indexed) {
      bus.write32(_code + 4 * i, inst);
    }
    cpu.pc = _code;
    cpu.nextPc = _code + 4;
  }

  double mips(Stopwatch sw, int clocks) => clocks / 2 / sw.elapsedMicroseconds;

  final bus = Bus(), cpu = R3000(bus);
  load(bus, cpu);
  final sw = Stopwatch()..start();
  while (cpu.pc != _end) {
    cpu.step();
  }
  final checksum = cpu.r[12];
  print('interpreter: ${mips(sw, cpu.clocks).toStringAsFixed(1)} MIPS');

  for (final native in [false, true]) {
    final jit = PsJit.create(native: native);
    if (jit == null) continue;
    final bus = Bus(mem: jit.ram, rom: jit.rom, scratchPad: jit.scratchPad);
    final cpu = R3000(bus, regs: jit.regs);
    jit.attach(cpu, bus);
    for (final slice in native ? slices : [100000]) {
      jit.reset();
      load(bus, cpu);
      final sw = Stopwatch()..start();
      while (cpu.pc != _end) {
        jit.run(cpu.clocks + slice);
      }
      final ok = cpu.r[12] == checksum ? '' : ' (checksum differs)';
      print('${native ? 'compiled' : 'ir interpreter'} slice $slice: '
          '${mips(sw, cpu.clocks).toStringAsFixed(1)} MIPS$ok');
    }
    jit.rt.dispose();
  }
}
