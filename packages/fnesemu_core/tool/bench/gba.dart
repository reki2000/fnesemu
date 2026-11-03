// The GBA workloads of tool/bench.dart: a synthetic cartridge that
// needs no BIOS (the core's HLE boot reaches the entry directly).
//
// The entry fills a 4 KiB buffer in IWRAM, then an ARM outer loop
// calls a Thumb inner loop that folds the buffer into an accumulator
// with loads, multiplies and stores, for a fixed number of passes.
// The 'cpu' workload runs it on the interpreter and 'jit' on the JIT;
// both must produce the same checksum, which covers the buffer, the
// accumulator and the registers the program leaves behind.
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/gba/gba.dart';
import 'workload.dart';

const _buffer = 0x03000000; // IWRAM
const _done = 0x03001000; // accumulator cell, then the done flag
const _passes = 120;

int _fold(int hash, int value) =>
    ((hash ^ (value & 0xffffffff)) * 1099511628211) & 0x3fffffffffffffff;

// Minimal assemblers for the two instruction sets of the program.
int _imm(int value) {
  for (var rot = 0; rot < 16; rot++) {
    final n = rot * 2;
    final imm8 = ((value << n) | (value >> (32 - n))) & 0xffffffff;
    if (imm8 <= 0xff) return (rot << 8) | imm8;
  }
  throw ArgumentError('not encodable: $value');
}

int _dpI(int opcode, int rn, int rd, int value, {bool s = false}) =>
    0xe0000000 |
    (1 << 25) |
    (opcode << 21) |
    (s ? 1 << 20 : 0) |
    (rn << 16) |
    (rd << 12) |
    _imm(value);
int _dpS(int opcode, int rn, int rd, int amount, int type, int rm,
        {bool s = false}) =>
    0xe0000000 |
    (opcode << 21) |
    (s ? 1 << 20 : 0) |
    (rn << 16) |
    (rd << 12) |
    (amount << 7) |
    (type << 5) |
    rm;
int _mov(int rd, int value) => _dpI(13, 0, rd, value);
int _add(int rd, int rn, int value) => _dpI(4, rn, rd, value);
int _sub(int rd, int rn, int value, {bool s = false}) =>
    _dpI(2, rn, rd, value, s: s);
int _cmp(int rn, int value) => _dpI(10, rn, 0, value, s: true);
int _str(int rd, int rn, int offset) =>
    0xe5800000 | (rn << 16) | (rd << 12) | offset;
int _strR(int rd, int rn, int amount, int rm) =>
    0xe7800000 | (rn << 16) | (rd << 12) | (amount << 7) | rm;
int _b(int from, int to, {int cond = 14, bool link = false}) =>
    (cond << 28) |
    0x0a000000 |
    (link ? 1 << 24 : 0) |
    ((to - from - 2) & 0xffffff);

int _tAdds(int rd, int rn, int rm) => 0x1800 | (rm << 6) | (rn << 3) | rd;
int _tAddI(int rd, int imm8) => 0x3000 | (rd << 8) | imm8;
int _tLdr(int rd, int rn, int wordOffset) =>
    0x6800 | (wordOffset << 6) | (rn << 3) | rd;
int _tStr(int rd, int rn, int wordOffset) =>
    0x6000 | (wordOffset << 6) | (rn << 3) | rd;
int _tMuls(int rd, int rs) => 0x4000 | (0xd << 6) | (rs << 3) | rd;
int _tEors(int rd, int rs) => 0x4000 | (0x1 << 6) | (rs << 3) | rd;
int _tCmpR(int rn, int rm) => 0x4000 | (0xa << 6) | (rm << 3) | rn;
int _tMovHi(int rd, int rs) =>
    0x4400 | (2 << 8) | ((rd & 8) << 4) | ((rs & 8) << 3) | ((rs & 7) << 3) | (rd & 7);
int _tBx(int rs) => 0x4700 | (rs << 3);
int _tBcond(int cond, int from, int to) =>
    0xd000 | (cond << 8) | ((to - from - 2) & 0xff);

/// The cartridge image: a branch at the reset entry to the setup at
/// 0xc0, the ARM main loop at 0x1000 and the Thumb inner loop at
/// 0x1100.
Uint8List _rom() {
  final rom = Uint8List(0x2000);
  void w32(int offset, int value) =>
      rom.buffer.asByteData().setUint32(offset, value, Endian.little);
  void w16(int offset, int value) =>
      rom.buffer.asByteData().setUint16(offset, value, Endian.little);

  w32(0x00, _b(0, 0x30)); // b setup (0xc0 / 4 = 0x30)

  // setup (word index 0x30): fill the buffer, set the bases and the
  // accumulator, and branch into main.
  final setup = <int>[
    _mov(10, _buffer), // mov r10, #0x03000000
    _mov(11, _buffer), // mov r11, #0x03000000
    _add(11, 11, 0x1000), // add r11, r11, #0x1000 (the end / done base)
    _mov(1, 0), // mov r1, #0 (index)
    _mov(6, 0), // mov r6, #0 (accumulator)
    // fill: r3 = i * 37 + 11 + (i << 16)
    _dpS(13, 0, 3, 16, 0, 1), // mov r3, r1, lsl #16
    _dpS(4, 3, 3, 5, 0, 1), // add r3, r3, r1, lsl #5
    _dpS(4, 3, 3, 2, 0, 1), // add r3, r3, r1, lsl #2
    _dpS(4, 3, 3, 0, 0, 1), // add r3, r3, r1
    _add(3, 3, 11), // add r3, r3, #11
    _strR(3, 10, 2, 1), // str r3, [r10, r1, lsl #2]
    _add(1, 1, 1), // add r1, r1, #1
    _cmp(1, 1024), // cmp r1, #1024
    _b(0x30 + 13, 0x30 + 5, cond: 1), // bne fill
    _mov(9, _passes), // mov r9, #passes
    _b(0x30 + 15, 0x400), // b main
  ];
  for (final (i, word) in setup.indexed) {
    w32(0xc0 + 4 * i, word);
  }

  // main (word index 0x400 = byte 0x1000): call the Thumb inner loop
  // once per pass, then publish the accumulator and the done flag.
  final mainAt = 0x400;
  final main = <int>[
    // outer:
    _mov(0, 0x08000000), // mov r0, #0x08000000
    _add(0, 0, 0x1100), // add r0, r0, #0x1100
    _add(0, 0, 1), // add r0, r0, #1 (Thumb state)
    _dpS(13, 0, 14, 0, 0, 15), // mov lr, pc (the ARM return address)
    (0xe << 28) | 0x012fff10, // bx r0
    _sub(9, 9, 1, s: true), // subs r9, r9, #1
    _b(mainAt + 6, mainAt, cond: 1), // bne outer
    _str(6, 11, 0), // str r6, [r11] (accumulator)
    _mov(0, 1), // mov r0, #1
    _str(0, 11, 4), // str r0, [r11, #4] (done flag)
    0xea000000 - 2, // b .
  ];
  for (final (i, word) in main.indexed) {
    w32(0x1000 + 4 * i, word);
  }

  // inner (halfword index 0x880 = byte 0x1100): fold the buffer into
  // r6, four words per iteration.
  final inner = <int>[
    _tMovHi(4, 10), // mov r4, r10
    _tMovHi(5, 11), // mov r5, r11
    // loop:
    _tLdr(0, 4, 0), // ldr r0, [r4]
    _tLdr(1, 4, 1), // ldr r1, [r4, #4]
    _tMuls(0, 1), // muls r0, r1
    _tAdds(6, 6, 0), // adds r6, r6, r0
    _tEors(6, 1), // eors r6, r1
    _tLdr(2, 4, 2), // ldr r2, [r4, #8]
    _tLdr(3, 4, 3), // ldr r3, [r4, #12]
    _tMuls(2, 3), // muls r2, r3
    _tAdds(6, 6, 2), // adds r6, r6, r2
    _tStr(0, 4, 2), // str r0, [r4, #8]
    _tStr(2, 4, 3), // str r2, [r4, #12]
    _tAddI(4, 16), // adds r4, #16
    _tCmpR(4, 5), // cmp r4, r5
    _tBcond(1, 15, 2), // bne loop
    _tBx(14), // bx lr
  ];
  for (final (i, half) in inner.indexed) {
    w16(0x1100 + 2 * i, half);
  }
  return rom;
}

(int Function(), int) _run({required bool jit}) {
  final gba = Gba(jit: jit);
  if (jit && !gba.jitActive) {
    throw StateError('GBA JIT is unavailable on this host');
  }
  gba.setRom(_rom());
  var guard = 0;
  while (gba.bus.read32(_done + 4) == 0) {
    gba.exec(false);
    if (++guard > 4000000) throw StateError('GBA workload did not finish');
  }
  // Snapshot the checksum inputs before disposing the core: with the
  // JIT the register file lives in runtime memory the dispose frees.
  final buffer = [for (var i = 0; i < 0x1000; i += 4) gba.bus.read32(_buffer + i)];
  final regs = [...gba.cpu.regs.r];
  final cpsr = gba.cpu.regs.cpsr;
  final result = (() {
    var hash = 0xcbf29ce484222325;
    for (final word in buffer) {
      hash = _fold(hash, word);
    }
    for (final r in regs) {
      hash = _fold(hash, r);
    }
    return _fold(hash, cpsr);
  }, _passes * 1024);
  gba.dispose();
  return result;
}

(int Function(), int) _runCpu() => _run(jit: false);
(int Function(), int) _runJit() => _run(jit: true);

final gbaWorkloads = <String, BenchWorkload>{
  'cpu': (run: _runCpu, unit: 'words'),
  'jit': (run: _runJit, unit: 'words'),
};
