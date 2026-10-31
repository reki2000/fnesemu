// Synthetic benchmarks of the PS2 core that need no BIOS or disc.
//
// usage: dart build cli -t tool/ps2_bench.dart -o /tmp/ps2-bench
//        /tmp/ps2-bench/bundle/bin/ps2_bench
//            <ee|ee-fpu|jit|vu|dma|gs-sprite|gs-tri> [rounds]
//        (the jit workload needs the native library that dart build cli
//        bundles; an executable from dart compile exe cannot load it)
//        (dart run tool/ps2_bench.dart ... also works, but its times are
//        JIT VM times; build the AOT executable to decide speed, as in
//        tool/dart_aot_tips.md)
//
// Every workload prints a checksum that a faster version must keep equal.
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ps2/bus.dart';
import 'package:fnesemu_core/src/core/ps2/gs/gs.dart';
import 'package:fnesemu_core/src/core/ps2/gs/gs_memory.dart';
import 'package:fnesemu_core/src/core/ps2/jit/ps2_jit.dart';
import 'package:fnesemu_core/src/core/ps2/r5900/r5900.dart';
import 'package:fnesemu_core/src/core/ps2/vu.dart';

int _r(int rs, int rt, int rd, int funct, [int shift = 0]) =>
    rs << 21 | rt << 16 | rd << 11 | shift << 6 | funct;
int _i(int op, int rs, int rt, int imm) =>
    op << 26 | rs << 21 | rt << 16 | (imm & 0xffff);

const _code = 0x100000, _data = 0x200000;

// ---- EE interpreter: a checksum loop over a 4 KiB buffer ----

const _outer = int.fromEnvironment('BENCH_LOOPS', defaultValue: 3000);
final _eeProgram = [
  _i(0x0f, 0, 8, _data >> 16), // lui t0, data
  _i(0x09, 0, 16, _outer), // addiu s0, r0, outer
  _i(0x09, 8, 9, 0), // outer: addiu t1, t0, 0
  _i(0x09, 0, 10, 1024), // addiu t2, r0, 1024
  _i(0x23, 9, 11, 0), // inner: lw t3, 0(t1)
  _i(0x09, 10, 10, -1), // addiu t2, t2, -1
  _r(11, 12, 12, 0x21), // addu t4, t3, t4
  _r(0, 12, 13, 0x00, 3), // sll t5, t4, 3
  _r(13, 12, 12, 0x26), // xor t4, t5, t4
  _i(0x2b, 9, 12, 0x1000), // sw t4, 0x1000(t1)
  _i(0x05, 10, 0, -7), // bne t2, r0, inner
  _i(0x09, 9, 9, 4), // addiu t1, t1, 4 (delay slot)
  _i(0x09, 16, 16, -1), // addiu s0, s0, -1
  _i(0x05, 16, 0, -12), // bne s0, r0, outer
  0, // nop (delay slot)
  _i(0x02, 0, 0, 0) | (_code + 4 * 15) >> 2, // end: j end
  0,
];
const _eeEnd = _code + 4 * 15;

void _loadEe(Ps2Bus bus, R5900 cpu) {
  cpu.reset();
  for (var i = 0; i < 1024; i++) {
    bus.write32(_data + 4 * i, i * 2654435761 & 0xffffffff);
  }
  for (final (i, inst) in _eeProgram.indexed) {
    bus.write32(_code + 4 * i, inst);
  }
  cpu.jumpTo(_code);
}

(int Function(), int) _runEe() {
  final bus = Ps2Bus();
  final cpu = R5900(bus);
  _loadEe(bus, cpu);
  while (cpu.pc != _eeEnd) {
    if (!cpu.step()) throw StateError('unimplemented at 0x${cpu.pc}');
  }
  final checksum = cpu.reg(12);
  return (() => checksum, cpu.clocks);
}

(int Function(), int) _runJit() {
  final jit = Ps2Jit.create()!;
  final bus = Ps2Bus(ram: jit.ram);
  final cpu = R5900(bus, gpr: jit.gpr);
  jit.attach(cpu);
  _loadEe(bus, cpu);
  while (cpu.pc != _eeEnd) {
    if (!jit.run(100000)) {
      if (!cpu.step()) throw StateError('unimplemented at 0x${cpu.pc}');
    }
  }
  final checksum = cpu.reg(12);
  final result = (() => checksum, cpu.clocks);
  jit.dispose();
  return result;
}

// ---- EE FPU: an add/mul loop on COP1 ----

int _cop1(int fmt, int ft, int fs, int fd, int fn) =>
    17 << 26 | fmt << 21 | ft << 16 | fs << 11 | fd << 6 | fn;

final _fpuProgram = [
  _i(0x0f, 0, 9, 0x3f80), // lui t1, 0x3f80 (1.0)
  _cop1(4, 9, 1, 0, 0), // mtc1 t1, f1
  _i(0x0f, 0, 10, 0x3fc0), // lui t2, 0x3fc0 (1.5)
  _cop1(4, 10, 2, 0, 0), // mtc1 t2, f2
  _i(0x09, 0, 16, 2000), // addiu s0, r0, 2000
  _i(0x09, 0, 11, 10000), // outer: addiu t3, r0, 10000
  _cop1(16, 2, 1, 3, 0), // inner: add.s f3, f1, f2
  _cop1(16, 2, 3, 1, 2), // mul.s f1, f3, f2
  _i(0x09, 11, 11, -1), // addiu t3, t3, -1
  _i(0x05, 11, 0, -4), // bne t3, r0, inner
  0, // nop (delay slot)
  _i(0x09, 16, 16, -1), // addiu s0, s0, -1
  _i(0x05, 16, 0, -8), // bne s0, r0, outer
  0, // nop (delay slot)
  _i(0x02, 0, 0, 0) | (_code + 4 * 14) >> 2, // end: j end
  0,
];
const _fpuEnd = _code + 4 * 14;

(int Function(), int) _runFpu() {
  final bus = Ps2Bus();
  final cpu = R5900(bus);
  cpu.reset();
  for (final (i, inst) in _fpuProgram.indexed) {
    bus.write32(_code + 4 * i, inst);
  }
  cpu.jumpTo(_code);
  while (cpu.pc != _fpuEnd) {
    if (!cpu.step()) throw StateError('unimplemented at 0x${cpu.pc}');
  }
  final checksum = cpu.fpr[1];
  return (() => checksum, cpu.clocks);
}

// ---- DMA primitive: the physical 64-bit accesses the DMAC makes for
// every quadword it moves ----

(int Function(), int) _runDma() {
  final bus = Ps2Bus();
  var hash = 0;
  const rounds = 200, words = 1 << 17; // 1 MiB of quadword halves
  for (var n = 0; n < rounds; n++) {
    for (var i = 0; i < words; i++) {
      final a = i * 8;
      bus.writePhysical64(a, hash + i);
      hash = bus.readPhysical64(a) ^ (hash << 1);
    }
  }
  final checksum = hash;
  return (() => checksum, rounds * words);
}

// ---- VU1: FMAC pairs with a branch back to the start ----

int _up(int op, int dest, int fd, int fs, int ft) =>
    dest << 21 | ft << 16 | fs << 11 | fd << 6 | op;

(int Function(), int) _runVu() {
  final vu = Vu(1);
  const pairs = 64;
  // ADD, MUL and the broadcast forms, rotating the destination so that no
  // pair reads a register an earlier pair has not finished writing
  const ops = [0x28, 0x2a, 0x01, 0x18, 0x29, 0x02, 0x1a, 0x2c];
  for (var p = 0; p < pairs; p++) {
    vu.micro[p * 2] = 0x8000033c; // lower NOP
    vu.micro[p * 2 + 1] = _up(ops[p % ops.length], 15, 3 + p % 16, 1, 2);
  }
  vu.micro[pairs * 2] = (0x20 << 25) | (-pairs - 1 & 0x7ff); // B 0
  vu.micro[pairs * 2 + 1] = 0x000002ff; // upper NOP
  final f = ByteData(4);
  void setVf(int reg, List<double> v) {
    for (var c = 0; c < 4; c++) {
      f.setFloat32(0, v[c]);
      vu.vf[reg * 4 + c] = f.getUint32(0);
    }
  }

  setVf(1, [1.5, -2.25, 3.75, 0.5]);
  setVf(2, [0.25, 4.5, -1.125, 2.0]);
  const total = 2000000;
  vu.start(0, maxPairs: total);
  var hash = vu.cycles;
  for (var i = 0; i < vu.vf.length; i++) {
    hash = (hash * 31 + vu.vf[i]) & 0x3fffffffffffffff;
  }
  return (() => hash, total);
}

// ---- GS: textured sprites and triangles over a 256x256 CT32 frame ----

const _gsOffset = 2048 << 4;
int _xyz(num x, num y, [int z = 0]) =>
    ((x * 16).round() + _gsOffset) |
    (((y * 16).round() + _gsOffset) << 16) |
    (z << 32);

Gs _gsScene() {
  final gs = Gs();
  gs.writeRegister(0x4c, 0 | (4 << 16) | (GsPsm.ct32 << 24)); // FRAME_1
  gs.writeRegister(0x18, _gsOffset | (_gsOffset << 32)); // XYOFFSET_1
  gs.writeRegister(0x40, 255 << 16 | 255 << 48); // SCISSOR_1
  gs.writeRegister(0x4e, 2000 | (GsPsm.z32 << 24)); // ZBUF_1
  gs.writeRegister(0x47, (1 << 16) | (1 << 17)); // TEST_1: ZTE on, ALWAYS
  // a 128x128 CT32 texture at block 100
  for (var y = 0; y < 128; y++) {
    for (var x = 0; x < 128; x++) {
      gs.mem.write(GsPsm.ct32, 100, 2, x, y,
          (x * 2) | ((y * 2) << 8) | ((x ^ y) << 16) | (0x80 << 24));
    }
  }
  gs.writeRegister(
      0x06, 100 | (2 << 14) | (GsPsm.ct32 << 20) | (7 << 26) | (7 << 30));
  return gs;
}

int _gsHash(Gs gs) {
  var hash = 0x100000001b3;
  final bytes = gs.mem.bytes;
  for (var i = 0; i < bytes.length; i += 4) {
    hash = ((hash ^ bytes[i]) * 1099511628211) & 0x3fffffffffffffff;
  }
  return hash;
}

(int Function(), int) _runGsSprite() {
  final gs = _gsScene();
  const sprites = 30;
  for (var n = 0; n < sprites; n++) {
    gs.writeRegister(0x00, 6 | 0x10 | 0x100); // sprite, TME, FST
    gs.writeRegister(0x03, 0);
    gs.writeRegister(0x05, _xyz(0, 0, n));
    gs.writeRegister(0x03, (128 * 16) | ((128 * 16) << 16));
    gs.writeRegister(0x05, _xyz(256, 256, n));
  }
  // the hash walks all of GS memory, so it is taken outside the timed run
  return (() => _gsHash(gs), sprites * 256 * 256);
}

(int Function(), int) _runGsTri() {
  final gs = _gsScene();
  const tris = 300;
  final f = ByteData(4);
  int bits(double v) {
    f.setFloat32(0, v);
    return f.getUint32(0);
  }

  for (var n = 0; n < tris; n++) {
    final x0 = (n * 37) % 128, y0 = (n * 53) % 128;
    gs.writeRegister(0x00, 3 | 0x10 | 0x08); // triangle, TME, IIP
    void vertex(num x, num y, double s, double t, int rgb) {
      gs.writeRegister(0x01, rgb | (0x80 << 24) | (bits(1.0) << 32));
      gs.writeRegister(0x02, bits(s) | (bits(t) << 32));
      gs.writeRegister(0x05, _xyz(x, y, 100 + n));
    }

    vertex(x0, y0, 0, 0, 0x102030);
    vertex(x0 + 128, y0 + 16, 1, 0.125, 0x405060);
    vertex(x0 + 16, y0 + 128, 0.125, 1, 0x708090);
  }
  return (() => _gsHash(gs), tris);
}

void main(List<String> args) {
  final name = args.isEmpty ? 'ee' : args[0];
  final rounds = args.length > 1 ? int.parse(args[1]) : 5;
  final (run, unit) = switch (name) {
    'ee' => (_runEe, 'instructions'),
    'ee-fpu' => (_runFpu, 'instructions'),
    'jit' => (_runJit, 'instructions'),
    'vu' => (_runVu, 'pairs'),
    'dma' => (_runDma, 'quadword halves'),
    'gs-sprite' => (_runGsSprite, 'pixels'),
    'gs-tri' => (_runGsTri, 'triangles'),
    _ => throw ArgumentError('unknown workload: $name'),
  };
  int? checksum;
  var best = double.infinity;
  for (var round = 0; round < rounds; round++) {
    final sw = Stopwatch()..start();
    final (hashOf, count) = run();
    sw.stop();
    final hash = hashOf();
    checksum ??= hash;
    if (hash != checksum) {
      throw StateError('checksum changed between rounds: $hash');
    }
    final ms = sw.elapsedMicroseconds / 1000;
    if (ms < best) best = ms;
    print('round $round: ${ms.toStringAsFixed(1)} ms '
        '(${(count / (ms / 1000)).toStringAsFixed(0)} $unit/s)');
  }
  print('$name: best ${best.toStringAsFixed(1)} ms, checksum $checksum');
}
