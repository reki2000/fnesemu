// Synthetic benchmarks of the PS1 core that need no BIOS or disc.
//
// usage: dart build cli -t tool/ps_bench.dart -o /tmp/ps-bench
//        /tmp/ps-bench/bundle/bin/ps_bench
//            <cpu|jit|gte|gpu-gouraud|gpu-textured|spu> [rounds]
//        (the jit workload needs the native library that dart build cli
//        bundles; an executable from dart compile exe cannot load it)
//        (dart run tool/ps_bench.dart ... also works, but its times are
//        JIT VM times; build the AOT executable to decide speed, as in
//        tool/dart_aot_tips.md)
//
// Every workload prints a checksum that a faster version must keep equal.
import 'package:fnesemu_core/src/core/ps/bus.dart';
import 'package:fnesemu_core/src/core/ps/gpu/gpu.dart';
import 'package:fnesemu_core/src/core/ps/jit/ps_jit.dart';
import 'package:fnesemu_core/src/core/ps/ps.dart';
import 'package:fnesemu_core/src/core/ps/r3000/r3000.dart';

int _r(int rs, int rt, int rd, int funct, [int shift = 0]) =>
    rs << 21 | rt << 16 | rd << 11 | shift << 6 | funct;
int _i(int op, int rs, int rt, int imm) =>
    op << 26 | rs << 21 | rt << 16 | (imm & 0xffff);

// ---- CPU: the checksum loop of tool/ps_jit_bench.dart over real RAM ----

const _code = 0x80010000;
const _outer = int.fromEnvironment('BENCH_LOOPS', defaultValue: 3000);
final _program = [
  _i(0x0f, 0, 8, 0x8010), // lui t0, 0x8010
  _i(0x09, 0, 16, _outer), // addiu s0, r0, outer
  _i(0x09, 8, 9, 0), // outer: addiu t1, t0, 0
  _i(0x09, 0, 10, 1024), // addiu t2, r0, 1024
  _i(0x23, 9, 11, 0), // inner: lw t3, 0(t1)
  _i(0x09, 10, 10, -1), // addiu t2, t2, -1
  _r(11, 12, 12, 0x21), // addu t4, t4, t3
  _r(12, 0, 13, 0x00, 3), // sll t5, t4, 3
  _r(13, 12, 12, 0x26), // xor t4, t4, t5
  _i(0x2b, 9, 12, 0x1000), // sw t4, 0x1000(t1)
  _i(0x05, 10, 0, -7), // bne t2, r0, inner
  _i(0x09, 9, 9, 4), // addiu t1, t1, 4 (delay slot)
  _i(0x09, 16, 16, -1), // addiu s0, s0, -1
  _i(0x05, 16, 0, -12), // bne s0, r0, outer
  0, // nop (delay slot)
  _i(0x02, 0, 0, 0) | (_end >> 2) & 0x3ffffff, // end: j end
  0,
];
const _end = _code + 4 * 15;

void _loadCpu(Bus bus, R3000 cpu) {
  cpu.reset();
  for (var i = 0; i < 1024; i++) {
    bus.write32(0x80100000 + 4 * i, i * 2654435761 & 0xffffffff);
  }
  for (final (i, inst) in _program.indexed) {
    bus.write32(_code + 4 * i, inst);
  }
  cpu.pc = _code;
  cpu.nextPc = _code + 4;
}

(int Function(), int) _runCpu() {
  final bus = Bus();
  final cpu = R3000(bus);
  _loadCpu(bus, cpu);
  while (cpu.pc != _end) {
    cpu.step();
  }
  final checksum = cpu.r[12];
  // the R3000 counts two clocks per instruction
  return (() => checksum, cpu.clocks ~/ 2);
}

(int Function(), int) _runJit() {
  final jit = PsJit.create();
  if (jit == null) {
    print('jit: PsJit.create() returned null on this host, skipping');
    return (() => 0, 0);
  }
  final bus = Bus(mem: jit.ram, rom: jit.rom, scratchPad: jit.scratchPad);
  final cpu = R3000(bus, regs: jit.regs);
  jit.attach(cpu, bus);
  _loadCpu(bus, cpu);
  while (cpu.pc != _end) {
    jit.run(cpu.clocks + 100000);
  }
  final checksum = cpu.r[12];
  final result = (() => checksum, cpu.clocks ~/ 2);
  jit.dispose();
  return result;
}

// ---- GTE: transform and lighting commands on the COP2 of a bare R3000 ----

(int Function(), int) _runGte() {
  final cop2 = R3000(Bus()).cop2;
  int xy(int x, int y) => (x & 0xffff) | (y & 0xffff) << 16;
  // an identity-like rotation with a small skew, and a translation
  cop2.writeCtrl(0, xy(0x1000, 0)); // R11, R12
  cop2.writeCtrl(1, xy(0, 0x1000)); // R13, R21
  cop2.writeCtrl(2, xy(0, 0)); // R22, R23
  cop2.writeCtrl(3, xy(0x1000, 0)); // R31, R32
  cop2.writeCtrl(4, 0x1000); // R33
  cop2.writeCtrl(5, 100); // TRX
  cop2.writeCtrl(6, -50); // TRY
  cop2.writeCtrl(7, 1000); // TRZ
  cop2.writeCtrl(24, 160 << 16); // OFX
  cop2.writeCtrl(25, 120 << 16); // OFY
  cop2.writeCtrl(26, 240); // H
  cop2.writeCtrl(27, 0); // DQA
  cop2.writeCtrl(28, 0); // DQB
  cop2.writeCtrl(29, 0x555); // ZSF3
  cop2.writeCtrl(30, 0x400); // ZSF4
  // the light matrix and the background color for the lighting commands
  cop2.writeCtrl(8, xy(0x1000, 0));
  cop2.writeCtrl(9, xy(0, 0x1000));
  cop2.writeCtrl(10, xy(0, 0));
  cop2.writeCtrl(11, xy(0x1000, 0));
  cop2.writeCtrl(12, 0x1000);
  cop2.writeCtrl(13, 0x2000); // RBK
  cop2.writeCtrl(14, 0x2000); // GBK
  cop2.writeCtrl(15, 0x2000); // BBK
  cop2.writeReg(6, 0x808080); // RGBC

  const sf = 1 << 19; // GTE commands with the 12-bit fraction shift
  const commands = [
    0x4a000000 | sf | 0x30, // RTPT: transform V0, V1 and V2
    0x4a000000 | sf | 0x06, // NCLIP: the screen area of the triangle
    0x4a000000 | sf | 0x2d, // AVSZ3: the average Z
    0x4a000000 | sf | 0x12, // MVMVA: matrix times the V2 vector
    0x4a000000 | sf | 0x1e, // NCS: lighting of V0
    0x4a000000 | sf | 0x28, // SQR: the squared vector
  ];
  const iterations = 200000;
  var seed = 12345;
  int next() => seed = (seed * 1103515245 + 12345) & 0x7fffffff;
  var hash = 0;
  for (var n = 0; n < iterations; n++) {
    cop2.writeReg(0, xy(next() % 2001 - 1000, next() % 2001 - 1000));
    cop2.writeReg(1, 500 + next() % 1000); // VZ0
    cop2.writeReg(2, xy(next() % 2001 - 1000, next() % 2001 - 1000));
    cop2.writeReg(3, 500 + next() % 1000); // VZ1
    cop2.writeReg(4, xy(next() % 2001 - 1000, next() % 2001 - 1000));
    cop2.writeReg(5, 500 + next() % 1000); // VZ2
    for (final cmd in commands) {
      cop2.execCmd(cmd);
    }
    hash = (hash * 31 + cop2.readReg(14) + cop2.readReg(24)) & 0x3fffffffffffffff;
  }
  final checksum = hash;
  return (() => checksum, iterations * commands.length);
}

// ---- GPU: GP0 polygon streams over a full drawing area ----

Gpu _gpuScene() {
  final gpu = Gpu(Bus());
  gpu.drawingX1 = 0;
  gpu.drawingY1 = 0;
  gpu.drawingX2 = 1023;
  gpu.drawingY2 = 511;
  gpu.drawingOffsetX = 0;
  gpu.drawingOffsetY = 0;
  // a texture pattern with no transparent (zero) texels
  for (var i = 0; i < gpu.frameBuffer16.length; i++) {
    gpu.frameBuffer16[i] = (i * 31 & 0x7fff) + 1;
  }
  return gpu;
}

int _gpuHash(Gpu gpu) {
  var hash = 0x100000001b3;
  final fb = gpu.frameBuffer16;
  for (var i = 0; i < fb.length; i++) {
    hash = ((hash ^ fb[i]) * 1099511628211) & 0x3fffffffffffffff;
  }
  return hash;
}

class _Lcg {
  int _seed;
  _Lcg(this._seed);
  int next(int bound) {
    _seed = (_seed * 1103515245 + 12345) & 0x7fffffff;
    return _seed % bound;
  }
}

(int Function(), int) _runGpuGouraud() {
  final gpu = _gpuScene();
  final rng = _Lcg(999);
  const tris = 4000;
  for (var n = 0; n < tris; n++) {
    final x = rng.next(800), y = rng.next(350);
    final w = 60 + rng.next(140), h = 60 + rng.next(140);
    int vertex(int vx, int vy) => vx | vy << 16;
    int color() => rng.next(0x1000000);
    gpu.writeGp0(0x30000000 | color());
    gpu.writeGp0(vertex(x, y));
    gpu.writeGp0(color());
    gpu.writeGp0(vertex(x + w, y + h ~/ 3));
    gpu.writeGp0(color());
    gpu.writeGp0(vertex(x + w ~/ 3, y + h));
  }
  return (() => _gpuHash(gpu), tris);
}

(int Function(), int) _runGpuTextured() {
  final gpu = _gpuScene();
  final rng = _Lcg(4242);
  const tris = 4000;
  for (var n = 0; n < tris; n++) {
    final x = rng.next(800), y = rng.next(350);
    final w = 60 + rng.next(140), h = 60 + rng.next(140);
    int vertex(int vx, int vy) => vx | vy << 16;
    int color() => rng.next(0x1000000);
    int uv(int u, int v, [int high = 0]) => u | v << 8 | high << 16;
    gpu.writeGp0(0x3c000000 | color());
    gpu.writeGp0(vertex(x, y));
    gpu.writeGp0(uv(0, 0)); // the CLUT address is unused in 15-bit mode
    gpu.writeGp0(color());
    gpu.writeGp0(vertex(x + w, y + h ~/ 3));
    gpu.writeGp0(uv(255, 32, 0x100)); // texture page: base 0, 15-bit color
    gpu.writeGp0(color());
    gpu.writeGp0(vertex(x + w ~/ 3, y + h));
    gpu.writeGp0(uv(32, 255));
  }
  return (() => _gpuHash(gpu), tris);
}

// ---- SPU: voices looping ADPCM streams, mixed at 44100 Hz ----

(int Function(), int) _runSpu() {
  final ps = Ps(jit: false);
  final spu = ps.spu;
  const voicesUsed = 8;
  const streamBlocks = 64;
  for (var v = 0; v < voicesUsed; v++) {
    final base = 0x10000 + v * 0x1000;
    for (var b = 0; b < streamBlocks; b++) {
      final at = base + b * 16;
      spu.ram[at] = 0x23; // ADPCM filter 2, shift 3
      // the last block loops back to the repeat address
      spu.ram[at + 1] = b == streamBlocks - 1 ? 0x03 : 0x00;
      for (var i = 0; i < 14; i++) {
        spu.ram[at + 2 + i] = (b * 37 + i * 91 + v * 53) & 0xff;
      }
    }
    spu.writeVoice(0x06, v, base >> 3); // start address
    spu.writeVoice(0x0e, v, base >> 3); // repeat address
    spu.writeVoice(0x04, v, 0x0c00 + v * 0x80); // pitch around 1.0
    spu.writeVoice(0x00, v, 0x3fff); // left volume
    spu.writeVoice(0x02, v, 0x3fff); // right volume
    spu.writeVoice(0x08, v, 0x00ff); // ADSR low: fast attack, held sustain
    spu.writeVoice(0x0a, v, 0x1f00); // ADSR high
  }
  spu.mainVolumeLeft = 0x3fff;
  spu.mainVolumeRight = 0x3fff;
  spu.writeCtrl(0xc000); // enabled and not muted
  spu.keyOn((1 << voicesUsed) - 1);
  // let the attack envelopes settle before the timed run
  for (var i = 0; i < 512; i++) {
    spu.renderSample();
  }
  const samples = 441000; // ten seconds of output
  var hash = 0;
  for (var n = 0; n < samples; n++) {
    spu.renderSample();
    final l = (spu.outLeft * 32768).toInt(), r = (spu.outRight * 32768).toInt();
    hash = (hash * 31 + l * 3 + r) & 0x3fffffffffffffff;
  }
  final checksum = hash;
  ps.dispose();
  return (() => checksum, samples);
}

void main(List<String> args) {
  final name = args.isEmpty ? 'cpu' : args[0];
  final rounds = args.length > 1 ? int.parse(args[1]) : 5;
  final (run, unit) = switch (name) {
    'cpu' => (_runCpu, 'instructions'),
    'jit' => (_runJit, 'instructions'),
    'gte' => (_runGte, 'commands'),
    'gpu-gouraud' => (_runGpuGouraud, 'triangles'),
    'gpu-textured' => (_runGpuTextured, 'triangles'),
    'spu' => (_runSpu, 'samples'),
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
