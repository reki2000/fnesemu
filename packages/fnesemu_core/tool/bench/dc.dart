// The DC workloads of tool/bench.dart: synthetic benchmarks of the DC core that need no BIOS or disc.
//
// Every workload returns a checksum that a faster version must keep equal.
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:fnesemu_core/src/core/dc/sh4.dart';
import 'package:fnesemu_core/src/types.dart';
import 'package:fnesemu_core/src/util/uint8list.dart';
import 'workload.dart';

const _code = 0x8c010000, _data = 0x8c020000;

// A checksum loop over a 4 KiB buffer in cached RAM: each pass reloads the
// inner count and the pointer, folds every longword into R13 with add and
// xor, and stores the accumulator back over the buffer.
//   MOV R11, R10        reload the inner count
//   MOV R8, R9          reload the pointer
// inner:
//   MOV.L @R9, R12
//   ADD R12, R13
//   XOR R13, R12
//   ADD R12, R13
//   MOV.L R13, @R9
//   ADD #4, R9
//   DT R10
//   BF inner
//   DT R14              (finite form only)
//   BF start            (finite form only)
//   BRA end / BRA start
//   NOP
const _loopHead = [
  0x6ab3, 0x6983, 0x6c92, 0x3dcc, 0x2cda, 0x3dcc, //
  0x19d0, 0x7904, 0x4a10, 0x8bf7,
];
const _loopFinite = [..._loopHead, 0x4e10, 0x8bf3, 0xaffe, 0x0009];
const _loopForever = [..._loopHead, 0xaff4, 0x0009];
const _loopEnd = _code + 24;

int _fold(int hash, int value) =>
    ((hash ^ (value & 0xffffffff)) * 1099511628211) & 0x3fffffffffffffff;

void _fillData(void Function(int address, int value) write32) {
  for (var i = 0; i < 1024; i++) {
    write32(_data + 4 * i, i * 2654435761 & 0xffffffff);
  }
}

// ---- SH-4 interpreter: the checksum loop with caches enabled, as the
// BIOS configures them (CCR 0x105), and with the interrupt scan cached,
// as Dc.runFrame drives the CPU ----

(int Function(), int) _runCpu() {
  final bus = DcBus();
  final cpu = Sh4(bus);
  cpu.cacheInterrupts = true;
  for (final (i, word) in _loopFinite.indexed) {
    bus.write16(_code + 2 * i, word);
  }
  _fillData(bus.write32);
  // The caches are enabled after the code and data are in RAM, as a boot
  // ROM leaves them; bus writes made with the operand cache already on
  // would sit in it as copy-back lines the instruction fill cannot see.
  bus.write32(0xff00001c, 0x105);
  cpu.r[8] = _data;
  cpu.r[11] = 1024;
  cpu.r[14] = 2000;
  cpu.pc = _code;
  var steps = 0;
  while (cpu.pc != _loopEnd) {
    cpu.step();
    steps++;
  }
  final checksum = cpu.r[13];
  return (() => checksum, steps);
}

// ---- SH-4 JIT: the same loop, constructed the way Dc wires it ----

(int Function(), int) _runJit() {
  final jit = Sh4Jit.create();
  if (jit == null) throw StateError('SH-4 JIT is unavailable on this host');
  final bus = DcBus(ram: jit.ram, storeQueues: jit.storeQueues);
  bus.cache.coherent = true;
  final cpu = Sh4(bus, jit: jit);
  for (final (i, word) in _loopFinite.indexed) {
    bus.ram.setUint16LE(0x10000 + 2 * i, word);
  }
  _fillData((address, value) =>
      bus.ram.setUint32LE(address & (DcBus.ramSize - 1), value));
  cpu.r[8] = _data;
  cpu.r[11] = 1024;
  cpu.r[14] = 2000;
  cpu.pc = _code;
  var steps = 0, guard = 100000;
  while (cpu.pc != _loopEnd && guard-- > 0) {
    final ran = cpu.runCompiled(100000);
    if (ran == 0) {
      cpu.step();
      steps++;
    } else {
      steps += ran;
    }
  }
  if (cpu.pc != _loopEnd) throw StateError('compiled loop did not finish');
  final checksum = cpu.r[13];
  final result = (() => checksum, steps);
  jit.dispose();
  return result;
}

// ---- SH-4 FPU: an FADD/FMUL dependency chain in single precision ----

//   MOV R11, R10        reload the inner count
// inner:
//   FADD FR1, FR3
//   FMUL FR2, FR3
//   FADD FR3, FR1
//   DT R10
//   BF inner
//   DT R14
//   BF start
//   BRA end
//   NOP
const _fpuProgram = [
  0x6ab3, 0xf310, 0xf322, 0xf130, 0x4a10, //
  0x8bfa, 0x4e10, 0x8bf7, 0xaffe, 0x0009,
];
const _fpuEnd = _code + 16;

(int Function(), int) _runFpu() {
  final bus = DcBus();
  final cpu = Sh4(bus);
  cpu.cacheInterrupts = true;
  for (final (i, word) in _fpuProgram.indexed) {
    bus.write16(_code + 2 * i, word);
  }
  bus.write32(0xff00001c, 0x105); // After the code is in RAM, as in _runCpu.
  final bits = ByteData(4);
  void setFr(int reg, double value) {
    bits.setFloat32(0, value);
    cpu.fr[reg] = bits.getUint32(0);
  }

  setFr(1, 1.5);
  setFr(2, 0.25);
  setFr(3, 0.5);
  cpu.fpscr = 0x40000; // Round to nearest, as in the compiled-core test.
  cpu.r[11] = 4096;
  cpu.r[14] = 100;
  cpu.pc = _code;
  var steps = 0;
  while (cpu.pc != _fpuEnd) {
    cpu.step();
    steps++;
  }
  final checksum = cpu.fr[1];
  return (() => checksum, steps);
}

// ---- Whole frames: the checksum loop as a diagnostic ROM, run through
// Dc.runFrame with the SPG stopped, as in the core tests ----

(int Function(), int) _runFrame() {
  final rom = Uint8List(_loopForever.length * 2);
  for (final (i, word) in _loopForever.indexed) {
    rom.setUint16LE(2 * i, word);
  }
  final core = Dc(jit: false)..setRom(rom);
  _fillData(core.bus.write32);
  core.cpu.r[8] = _data;
  core.cpu.r[11] = 1024;
  const frames = 10;
  for (var i = 0; i < frames; i++) {
    final result = core.runFrame(525);
    if (result.stopped) throw StateError('frame stopped: ${core.stopReason}');
  }
  var hash = _fold(0x100000001b3, core.cpu.r[13]);
  for (var i = 0; i < 1024; i++) {
    hash = _fold(hash, core.bus.read32(_data + 4 * i));
  }
  final clocks = core.cpuClocks;
  core.dispose();
  return (() => hash, clocks);
}

// ---- PowerVR: TA submission of flat and Gouraud triangles over one
// 32x32 tile, then a render to a 32-bit framebuffer in VRAM ----

int _floatBits(double value) {
  final data = ByteData(4)..setFloat32(0, value, Endian.little);
  return data.getUint32(0, Endian.little);
}

(int Function(), int) _runGpu() {
  const reg = 0xa05f8000, object = 0x100000, parameter = 0x200000;
  const copy = 0x20800000; // Source one, destination zero, no fog.
  final bus = DcBus();
  void packet(List<int> words) {
    final bytes = Uint8List(32);
    for (final (i, word) in words.indexed) {
      bytes.setUint32LE(i * 4, word);
    }
    bus.gpu.writePolygon(bytes);
  }

  bus.write32(reg + 8, 0);
  for (final entry in [
    (0x124, object),
    (0x128, parameter),
    (0x12c, object + 0xffe0),
    (0x130, parameter + 0xfffc),
    (0x13c, 0),
    (0x140, 1),
    (0x164, object + 0x1000)
  ]) {
    bus.write32(reg + entry.$1, entry.$2);
  }
  bus.write32(reg + 0x144, 0x80000000);
  void vertex(double x, double y, double z, int color, bool end) => packet([
        end ? 0xf0000000 : 0xe0000000,
        _floatBits(x),
        _floatBits(y),
        _floatBits(z),
        color,
        0,
        0,
        0
      ]);
  const triangles = 400;
  for (var n = 0; n < triangles; n++) {
    final gouraud = n.isOdd;
    packet(
        [gouraud ? 0x80800002 : 0x80800000, 0xe0000000, copy, 0, 0, 0, 0, 0]);
    final x = (n * 7) % 24, y = (n * 11) % 24;
    final z = 1 + (n % 8) * 0.25;
    vertex(x.toDouble(), y.toDouble(), z, 0xffff0000, false);
    vertex(x + 16.0, y.toDouble(), z, gouraud ? 0xff00ff00 : 0xffff0000, false);
    vertex(x.toDouble(), y + 16.0, z, gouraud ? 0xff0000ff : 0xffff0000, true);
  }
  packet([0]);
  // A self-authored flat background plane, as in the TA tests.
  final vram = bus.gpu.vram;
  void put(int offset, List<int> words) {
    for (final (i, value) in words.indexed) {
      vram.setUint32LE(offset + i * 4, value);
    }
  }

  put(parameter + 0x8000,
      [0xe0000000, copy, 0, 0, 0, 0, 0xff000000, 0, 0, 0, 0xff000000, 0, 0, 0, 0xff000000]);
  for (final entry in [
    (0x20, parameter),
    (0x2c, 0x9000),
    (0x48, 6),
    (0x4c, 16),
    (0x60, 0x400000),
    (0x68, 31 << 16),
    (0x6c, 31 << 16),
    (0x8c, (1 << 24) | ((0x8000 >> 2) << 3)),
    (0x88, 0)
  ]) {
    bus.write32(reg + entry.$1, entry.$2);
  }
  put(0x9000, [0x80000000, object, 0x80000000, 0x80000000, 0x80000000]);
  bus.write32(reg + 0x14, 1);
  var guard = 2000000;
  while (bus.gpu.render.busy) {
    bus.tickMasterClocks(64);
    if (guard-- == 0) throw StateError('render did not finish');
  }
  int checksum() {
    var hash = 0x100000001b3;
    for (var i = 0; i < 1024; i++) {
      hash = _fold(hash, vram.getUint32LE(0x400000 + 4 * i));
    }
    return hash;
  }

  return (checksum, triangles);
}

// ---- AICA: sixteen looping slots (PCM16, PCM8 and ADPCM) mixed for
// half a second of 44.1 kHz output ----

(int Function(), int) _runAica() {
  const base = 0xa0700000;
  final core = Dc(jit: false);
  final packets = <AudioBuffer>[];
  core.onAudio(packets.add);
  final memory = core.bus.aica.memory;
  for (var i = 0; i < 256; i++) {
    memory.setUint16LE(0x1000 + i * 2, (i * 2654435761 >> 16) & 0xffff);
    memory[0x1200 + i] = (i * 37) & 0xff;
    memory[0x1400 + i] = 0x88;
  }
  void configure(int slot, int format, int start, int pitch) {
    final bus = core.bus, address = base + slot * 0x80;
    bus.write32(address, 0x4000 | (format << 7) | 0x200);
    bus.write32(address + 4, start);
    bus.write32(address + 8, 0);
    bus.write32(address + 12, 255);
    bus.write32(address + 0x10, 31);
    bus.write32(address + 0x14, 0x3fe0);
    bus.write32(address + 0x18, pitch);
    bus.write32(address + 0x24, 15 << 8);
    bus.write32(address + 0x28, 4);
    for (var i = 0x2c; i <= 0x3c; i += 4) {
      bus.write32(address + i, 0x1ff8);
    }
    bus.write32(address, 0x8000 | 0x4000 | (format << 7) | 0x200);
  }

  core.bus.write32(base + 0x2800, 15);
  for (var slot = 0; slot < 16; slot++) {
    final format = slot < 12 ? 0 : (slot < 14 ? 1 : 2);
    final start = slot < 12 ? 0x1000 : (slot < 14 ? 0x1200 : 0x1400);
    configure(slot, format, start, (slot % 4) * 0x400);
  }
  // Half a second of samples in the batch sizes the frame loop uses.
  const totalClocks = 100000000;
  var clocks = 0;
  while (clocks < totalClocks) {
    core.bus.tickMasterClocks(8192);
    clocks += 8192;
  }
  final samples = packets.length * 256;
  int checksum() {
    var hash = 0x100000001b3;
    for (final packet in packets) {
      for (var i = 0; i < packet.buffer.length; i++) {
        hash = _fold(hash, (packet.buffer[i] * 32768).round());
      }
    }
    return hash;
  }

  final result = (checksum, samples);
  core.dispose();
  return result;
}

// The workloads of this core, by name.
// The first entry is the default workload of the core.
final dcWorkloads = <String, BenchWorkload>{
  'cpu': (run: _runCpu, unit: 'instructions'),
  'jit': (run: _runJit, unit: 'instructions'),
  'fpu': (run: _runFpu, unit: 'instructions'),
  'frame': (run: _runFrame, unit: 'clocks'),
  'gpu': (run: _runGpu, unit: 'triangles'),
  'aica': (run: _runAica, unit: 'samples'),
};
