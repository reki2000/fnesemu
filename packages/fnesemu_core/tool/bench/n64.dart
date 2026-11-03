// The N64 workloads of tool/bench.dart: synthetic benchmarks of the N64 core that need no ROM image on disc.
//
// The fixed integer loops of tool/n64_jit_bench.dart remain the targeted JIT comparison; the workloads here cover the wider hot paths of the core.
//
// Every workload returns a checksum that a faster version must keep equal.
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/n64/audio.dart';
import 'package:fnesemu_core/src/core/n64/bus.dart';
import 'package:fnesemu_core/src/core/n64/cpu.dart';
import 'package:fnesemu_core/src/core/n64/graphics.dart';
import 'package:fnesemu_core/src/core/n64/jit/n64_jit.dart';
import 'package:fnesemu_core/src/core/n64/n64.dart';
import 'workload.dart';

int _r(int rs, int rt, int rd, int funct, [int shift = 0]) =>
    rs << 21 | rt << 16 | rd << 11 | shift << 6 | funct;
int _i(int op, int rs, int rt, int imm) =>
    op << 26 | rs << 21 | rt << 16 | (imm & 0xffff);
int _j(int op, int addr) => op << 26 | (addr >> 2) & 0x3ffffff;

// ---- CPU and JIT: a 64-bit checksum loop over RDRAM through the real bus ----
//
// r4 holds the data base, as in tool/n64_jit_bench.dart. The inner loop loads
// a 64-bit word, folds it into the checksum with a shift and xor, and stores
// the result to a second buffer; the outer loop repeats over the buffer.

const _code = 0x80001000;
const _outer = int.fromEnvironment('BENCH_LOOPS', defaultValue: 2000);
// the closing jump targets the program's own end, which depends on where
// the program is placed, so the program is built for a given end address
List<int> _loopProgram(int end, [int outer = _outer]) => [
      _i(0x19, 0, 16, outer), // daddiu s0, r0, outer
      _i(0x09, 4, 9, 0), // outer: addiu t1, r4, 0
      _i(0x09, 0, 10, 256), // addiu t2, r0, 256
      _i(0x37, 9, 11, 0), // inner: ld t3, 0(t1)
      _i(0x19, 10, 10, -1), // daddiu t2, t2, -1
      _r(12, 11, 12, 0x2d), // daddu t4, t4, t3
      _r(0, 12, 13, 0x38, 3), // dsll t5, t4, 3
      _r(12, 13, 12, 0x26), // xor t4, t4, t5
      _i(0x3f, 9, 12, 0x800), // sd t4, 0x800(t1)
      _i(0x05, 10, 0, -7), // bne t2, r0, inner
      _i(0x19, 9, 9, 8), // daddiu t1, t1, 8 (delay slot)
      _i(0x19, 16, 16, -1), // daddiu s0, s0, -1
      _i(0x05, 16, 0, -12), // bne s0, r0, outer
      0, // nop (delay slot)
      _j(0x02, end), // end: j end
      0, // nop (delay slot)
    ];
const _end = _code + 4 * 14;
final _program = _loopProgram(_end);
const _instructions = 1 + _outer * (4 + 256 * 8);

void _loadProgram(N64Bus bus, int at) {
  for (var i = 0; i < 512; i++) {
    bus.ramWrite(0x2000 + 4 * i, i * 2654435761 & 0xffffffff, 4);
  }
  for (final (i, inst) in _program.indexed) {
    bus.ramWrite(at + 4 * i, inst, 4);
  }
}

(int Function(), int) _runCpu() {
  final bus = N64Bus();
  final cpu = Vr4300(bus);
  _loadProgram(bus, 0x1000);
  cpu.reset(_code);
  cpu.r[4] = 0x80002000.toSigned(32);
  var guard = 0;
  while (cpu.pc != _end) {
    cpu.step();
    if (cpu.stopReason != null) throw StateError(cpu.stopReason!);
    if (++guard > 100000000) throw StateError('cpu workload did not finish');
  }
  final checksum = cpu.r[12];
  return (() => checksum, _instructions);
}

(int Function(), int) _runJit() {
  final jit = N64Jit.create(compileThreshold: 1, inlineJumps: false);
  if (jit == null) {
    print('jit: N64Jit.create() returned null on this host, skipping');
    return (() => 0, 0);
  }
  final bus = N64Bus(ram: jit.ram);
  final cpu = Vr4300(bus, registers: jit.regs, fpu: jit.fpu);
  jit.attach(cpu, bus);
  _loadProgram(bus, 0x1000);
  cpu.reset(_code);
  cpu.r[4] = 0x80002000.toSigned(32);
  var guard = 0;
  while (cpu.pc != _end) {
    if (jit.run(256) != true) cpu.step();
    if (cpu.stopReason != null) throw StateError(cpu.stopReason!);
    if (++guard > 1000000) throw StateError('jit workload did not finish');
  }
  final checksum = cpu.r[12];
  final result = (() => checksum, _instructions);
  jit.dispose();
  return result;
}

// ---- Frame: whole frames of the real core on a synthetic ROM ----
//
// The ROM header and entry follow test/core/n64/frame_runner_test.dart; the
// payload is the checksum loop above, made self-contained (it sets its own
// data pointer). The loop runs for the first frames and then idles in its
// end jump, which the core fast-forwards. The interpreter core keeps the
// run deterministic.

(int Function(), int) _runFrame() {
  const frames = 20;
  final program = [
    _i(0x0f, 0, 4, 0x8000), // lui r4, 0x8000
    _i(0x0d, 4, 4, 0x2000), // ori r4, r4, 0x2000
    // a larger outer count keeps the loop busy for nearly all twenty frames
    ..._loopProgram(0x80000400 + 4 * 16, 15000),
  ];
  final rom = ByteData(0x1000 + program.length * 4);
  rom.setUint32(0, 0x80371240);
  rom.setUint32(8, 0x80000400);
  for (final (i, inst) in program.indexed) {
    rom.setUint32(0x1000 + 4 * i, inst);
  }
  final core = N64(jit: false)..setRom(rom.buffer.asUint8List());
  core.reset();
  for (var i = 0; i < 512; i++) {
    core.bus.ramWrite(0x2000 + 4 * i, i * 2654435761 & 0xffffffff, 4);
  }
  for (var f = 0; f < frames; f++) {
    core.runFrame(core.scanlinesInFrame);
    if (core.cpu.stopReason != null) {
      throw StateError(core.cpu.stopReason!);
    }
  }
  final bus = core.bus;
  int checksum() {
    var hash = core.cpu.r[12];
    for (var a = 0x2800; a < 0x2c00; a += 4) {
      hash = (hash * 31 + bus.ramRead(a, 4)) & 0x3fffffffffffffff;
    }
    return hash;
  }

  final result = (checksum, frames);
  core.dispose();
  return result;
}

// ---- RDP: sustained triangle streams through the software renderer ----

class _Lcg {
  int _seed;
  _Lcg(this._seed);
  int next(int bound) {
    _seed = (_seed * 1103515245 + 12345) & 0x7fffffff;
    return _seed % bound;
  }
}

const _fbAddress = 0x100000;
const _fbWidth = 320, _fbHeight = 240;

N64Graphics _rdpScene() {
  final bus = N64Bus()..reset();
  final g = N64Graphics(bus);
  g.width = _fbWidth;
  g.colorImage = _fbAddress;
  g.scLeft = 0;
  g.scTop = 0;
  g.scRight = _fbWidth;
  g.scBottom = _fbHeight;
  g.scale = Vec3(160, 120, 511);
  g.translate = Vec3(160, 120, 511);
  return g;
}

int _fbHash(N64Graphics g) {
  var hash = 0x100000001b3;
  final ram = g.bus.ram;
  for (var i = 0; i < _fbWidth * _fbHeight * 2; i++) {
    hash = ((hash ^ ram[_fbAddress + i]) * 1099511628211) & 0x3fffffffffffffff;
  }
  return hash;
}

void _drawTriangles(N64Graphics g, int count, _Lcg rng, bool textured) {
  for (var n = 0; n < count; n++) {
    final x = -0.95 + rng.next(110) / 100, y = -0.95 + rng.next(110) / 100;
    Rgba color() => Rgba(rng.next(256).toDouble(), rng.next(256).toDouble(),
        rng.next(256).toDouble(), 255);
    final s = textured ? 32.0 : 0.0;
    g.triangle(
        N64Vertex(Vec4(x, y, 0, 1), color(), 0, 0),
        N64Vertex(Vec4(x + 0.75, y + 0.25, 0, 1), color(), s, 8),
        N64Vertex(Vec4(x + 0.25, y + 0.75, 0, 1), color(), 8, s));
  }
}

(int Function(), int) _runRdpShaded() {
  final g = _rdpScene();
  // the shade-only combiner of the graphics tests: colour from the vertices
  g.combine1 = (7 << 28) | (4 << 15) | (7 << 12) | (6 << 9);
  const tris = 1200;
  _drawTriangles(g, tris, _Lcg(999), false);
  return (() => _fbHash(g), tris);
}

(int Function(), int) _runRdpTextured() {
  final g = _rdpScene();
  // a 32x32 RGBA16 texture in TMEM, texel alpha set so pixels are written
  for (var i = 0; i < 32 * 32; i++) {
    final v = (i * 37 & 0x7fff) | 1;
    g.tmem[2 * i] = v >> 8;
    g.tmem[2 * i + 1] = v & 0xff;
  }
  g.tiles[0]
    ..format = 0
    ..size = 2
    ..line = 8;
  g.textureOn = true;
  // the textured combiner of the graphics tests: colour from the texel
  g.combine0 = (1 << 12) | (6 << 9);
  g.combine1 = (7 << 28) | (1 << 15) | (7 << 12) | (7 << 9);
  const tris = 1200;
  _drawTriangles(g, tris, _Lcg(4242), true);
  return (() => _fbHash(g), tris);
}

// ---- RSP audio: one representative extended-ABI alist per task ----
//
// Per task: load an ADPCM stream, decode 1024 samples, resample, apply the
// eight-tap FIR, mix to left and right with gains, interleave and save the
// stereo output to RDRAM. The 1200 tasks process about 25 seconds of audio.

(int Function(), int) _runRspAudio() {
  final bus = N64Bus();
  final audio = N64Audio(bus);
  // the predictor book: two predictors of sixteen moderate coefficients
  for (var i = 0; i < 32; i++) {
    bus.ramWrite(0x3000 + 2 * i, (i * 733) % 4096 - 2048, 2);
  }
  // the ADPCM stream: 64 blocks of a header byte and eight data bytes
  for (var i = 0; i < 64 * 9; i++) {
    bus.ram[0x10000 + i] = (i * 91 + 17) & 0xff;
  }
  // the FIR coefficients the filter load reads
  for (var i = 0; i < 8; i++) {
    bus.ramWrite(0x3a00 + 2 * i, 4096 >> i, 2);
  }
  int cmd(int op, int flags, int low16) => op << 24 | flags << 16 | low16;
  final alist = <int>[
    cmd(11, 0, 64), 0x3000, // load the predictor book
    cmd(20, 0x40, 0), 0x10000, // load 1024 bytes of ADPCM to DMEM 0
    cmd(8, 0, 0), 0x400 << 16 | 2048, // setbuffer: in 0, out 0x400, count 2048
    cmd(1, 0, 0), 0x3800, // ADPCM decode, state in RDRAM
    cmd(8, 0, 0x400), 0xc00 << 16 | 1024, // setbuffer: in 0x400, out 0xc00
    cmd(5, 0, 0x8000), 0x3900, // resample at pitch 1.0, state in RDRAM
    cmd(7, 2, 1024), 0x3a00, // load the FIR coefficients and sample count
    cmd(7, 0, 0xc00), 0x3a00, // apply the FIR at DMEM 0xc00
    cmd(12, 64, 0x4000), 0xc00 << 16 | 0x1000, // mix to the left buffer
    cmd(12, 64, 0x3000), 0xc00 << 16 | 0x1400, // mix to the right buffer
    cmd(13, 64, 0x1800), 0x1000 << 16 | 0x1400, // interleave to DMEM 0x1800
    cmd(21, 128, 0x1800), 0x20000, // save the stereo output to RDRAM
  ];
  const tasks = 1200;
  for (var t = 0; t < tasks; t++) {
    for (var i = 0; i < alist.length; i++) {
      bus.ramWrite(0x8000 + 4 * i, alist[i], 4);
    }
    audio.task(0x8000, alist.length * 4, newer: true);
  }
  int checksum() {
    var hash = 0;
    for (var a = 0x20000; a < 0x20000 + 2048; a += 2) {
      hash = (hash * 31 + bus.ramRead(a, 2)) & 0x3fffffffffffffff;
    }
    return hash;
  }

  return (checksum, tasks * 1024);
}

// The workloads of this core, by name.
// The first entry is the default workload of the core.
final n64Workloads = <String, BenchWorkload>{
  'cpu': (run: _runCpu, unit: 'instructions'),
  'jit': (run: _runJit, unit: 'instructions'),
  'frame': (run: _runFrame, unit: 'frames'),
  'rdp-shaded': (run: _runRdpShaded, unit: 'triangles'),
  'rdp-textured': (run: _runRdpTextured, unit: 'triangles'),
  'rsp-audio': (run: _runRspAudio, unit: 'samples'),
};
