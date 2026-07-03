import 'dart:typed_data';

import 'arm7_asm.dart';

/// Builds a self-checking ARM7TDMI test ROM (.gba image).
///
/// Each case computes a value into r0 and compares it against the expected
/// value. Results are reported in EWRAM so both this emulator's test runner
/// and a reference emulator (mGBA etc.) can verify them:
///
///   0x02000000  fail count (0 = all passed)
///   0x02000004  id of the last failing case (1-based, 0 = none)
///   0x02000008  completion magic 0x600dc0de, written when the run finishes
///
/// The ROM needs no BIOS: it never uses SWI or interrupts. Note the header
/// carries no Nintendo logo, so it boots on emulators but not on real
/// hardware via the official BIOS check.
Uint8List buildCpuTestRom() {
  final code = <int>[];
  var id = 0;
  for (final (body, expected) in _cases) {
    id++;
    code.addAll(body);
    code.addAll(_check(id, expected));
  }
  // epilogue: write the completion magic and spin.
  code.addAll([
    aMovI(2, 2, rot4: 4), // r2 = 0x02000000
    ...aMovI32(1, 0x600dc0de),
    aStr(1, 2, 8),
    aBSelf,
  ]);
  return _withHeader(code);
}

/// compare r0 against [expected]; on mismatch bump the fail counter at
/// 0x02000000 and record this case's [id] at 0x02000004. Clobbers r1-r3.
List<int> _check(int id, int expected) => [
      ...aMovI32(1, expected),
      aCmpR(0, 1),
      aMovI(2, 2, rot4: 4, cond: condNe), // r2 = 0x02000000
      aLdr(3, 2, 0, cond: condNe),
      aAddI(3, 3, 1, cond: condNe),
      aStr(3, 2, 0, cond: condNe),
      aMovI(3, id, cond: condNe),
      aStr(3, 2, 4, cond: condNe),
    ];

/// r0 = NZCV nibble of the current flags.
List<int> _flagsToR0() => [
      aMrs(0),
      aMovR(0, 0, shType: shLsr, shImm: 28),
    ];

// (body, expected r0) pairs. Bodies are position-independent; data accesses
// use EWRAM at 0x02000100+ (the result block occupies 0x02000000..0x0b).
final _cases = <(List<int>, int)>[
  // adds 0x7fffffff + 1: N,V
  ([aMvnI(0, 2, rot4: 1), aAddI(0, 0, 1, s: true), ..._flagsToR0()], 0x9),
  // adds 0xffffffff + 1: Z,C
  ([aMvnI(0, 0), aAddI(0, 0, 1, s: true), ..._flagsToR0()], 0x6),
  // subs 3 - 5: value
  ([aMovI(0, 3), aSubI(0, 0, 5, s: true)], 0xfffffffe),
  // subs 3 - 5: borrow -> N only
  ([aMovI(0, 3), aSubI(0, 0, 5, s: true), ..._flagsToR0()], 0x8),
  // lsr #32: Z,C
  (
    [
      aMovI(0, 2, rot4: 1), // 0x80000000
      aMovR(1, 0, shType: shLsr, shImm: 0, s: true),
      ..._flagsToR0()
    ],
    0x6
  ),
  // asr #32: sign fill
  ([aMovI(0, 2, rot4: 1), aMovR(0, 0, shType: shAsr, shImm: 0)], 0xffffffff),
  // rrx with C=1
  (
    [aCmpR(0, 0), aMovI(0, 2), aMovR(0, 0, shType: shRor, shImm: 0)],
    0x80000001
  ),
  // adc: 1 + 2 + C(1)
  ([aCmpR(0, 0), aMovI(0, 1), aAdcI(0, 0, 2)], 4),
  // sbc with borrow-in: 5 - 1 - 1
  (
    [aMovI(1, 0), aAddI(1, 1, 0, s: true), aMovI(0, 5), aSbcI(0, 0, 1)],
    3
  ),
  // mul
  ([aMovI(1, 7), aMovI(2, 6), aMul(0, 1, 2)], 42),
  // mla
  ([aMovI(1, 7), aMovI(2, 6), aMovI(3, 5), aMla(0, 1, 2, 3)], 47),
  // umull lo/hi
  ([aMvnI(1, 0), aMovI(2, 2), aUmull(0, 3, 1, 2)], 0xfffffffe),
  ([aMvnI(1, 0), aMovI(2, 2), aUmull(3, 0, 1, 2)], 1),
  // smull hi: -1 * 2
  ([aMvnI(1, 0), aMovI(2, 2), aSmull(3, 0, 1, 2)], 0xffffffff),
  // shift by register
  ([aMovI(0, 1), aMovI(1, 4), aMovRS(0, 0, 1)], 16),
  // str pre-index writeback: r1 advances by the offset
  (
    [
      aMovI(1, 2, rot4: 4),
      aOrrI(1, 1, 1, rot4: 12), // r1 = 0x02000100
      aMovI(2, 0x77),
      aStr(2, 1, 4, wb: true),
      aSubI(0, 1, 2, rot4: 4),
      aSubI(0, 0, 1, rot4: 12),
    ],
    4
  ),
  // str/ldr roundtrip
  (
    [
      aMovI(1, 2, rot4: 4),
      aOrrI(1, 1, 1, rot4: 12),
      aMovI(2, 0x77),
      aStr(2, 1, 8),
      aLdr(0, 1, 8),
    ],
    0x77
  ),
  // unaligned ldr rotates data
  (
    [
      aMovI(1, 2, rot4: 4),
      aOrrI(1, 1, 1, rot4: 12),
      ...aMovI32(2, 0x11223344),
      aStr(2, 1, 0x10),
      aLdr(0, 1, 0x11),
    ],
    0x44112233
  ),
  // ldrsh sign extension
  (
    [
      aMovI(1, 2, rot4: 4),
      aOrrI(1, 1, 1, rot4: 12),
      ...aMovI32(2, 0x8081),
      aStrh(2, 1, 0x20),
      aLdrsh(0, 1, 0x20),
    ],
    0xffff8081
  ),
  // stmia writeback + reload: (r1-r5) + mem[base+8] = 12 + 0x33
  (
    [
      aMovI(5, 2, rot4: 4),
      aOrrI(5, 5, 2, rot4: 12), // r5 = 0x02000200
      aMovR(1, 5),
      aMovI(2, 0x11),
      aMovI(3, 0x22),
      aMovI(4, 0x33),
      aStm(1, 0x1c, wb: true), // stmia r1!, {r2-r4}
      aSubR(0, 1, 5),
      aLdr(3, 5, 8),
      aAddR(0, 0, 3),
    ],
    0x3f
  ),
  // bl: lr points at the skipped word ((pc@i2+8) - lr = 12)
  (
    [aBl(0), aMovI(0, 0xee), aMovR(1, 15), aSubR(0, 1, 14)],
    12
  ),
  // conditional execution
  (
    [aMovI(0, 0, s: true), aMovI(0, 5, cond: condEq), aMovI(0, 7, cond: condNe)],
    5
  ),
  // pc reads +8
  ([aMovR(1, 15), aMovR(2, 15), aSubR(0, 2, 1)], 4),
  // swp: old value + stored value = 0x77 + 0x88
  (
    [
      aMovI(1, 2, rot4: 4),
      aOrrI(1, 1, 3, rot4: 12), // r1 = 0x02000300
      aMovI(2, 0x77),
      aStr(2, 1, 0),
      aMovI(3, 0x88),
      aSwp(0, 3, 1),
      aLdr(4, 1, 0),
      aAddR(0, 0, 4),
    ],
    0xff
  ),
  // msr/mrs: set all flags, read them back
  ([aMsrFlagsI(0xf, rot4: 2), ..._flagsToR0()], 0xf),
  // thumb roundtrip: movs r0,#7; lsls r0,#2 in thumb, back via bx lr
  (
    [
      aMovR(1, 15), // r1 = here+8
      aAddI(1, 1, 13), // thumb code 3 words later, +1 for the thumb bit
      aMovR(14, 15), // lr = the `b` below (return target)
      aBx(1),
      aB(1), // jump over the thumb words to the check
      0x2007 | (tLslsI(0, 0, 2) << 16), // movs r0,#7; lsls r0,r0,#2
      tBxLr | (tNop << 16),
    ],
    28
  ),
];

/// wrap [code] (placed at ROM offset 0xc0) with a minimal cartridge header.
Uint8List _withHeader(List<int> code) {
  final rom = Uint8List(0xc0 + code.length * 4);

  // entry point: b 0xc0
  const entry = 0xea000000 | ((0xc0 - 8) >> 2);
  rom[0] = entry & 0xff;
  rom[1] = (entry >> 8) & 0xff;
  rom[2] = (entry >> 16) & 0xff;
  rom[3] = (entry >> 24) & 0xff;

  rom.setRange(0xa0, 0xa8, 'ARM7TEST'.codeUnits); // title
  rom.setRange(0xac, 0xb0, 'ATST'.codeUnits); // game code
  rom.setRange(0xb0, 0xb2, '01'.codeUnits); // maker code
  rom[0xb2] = 0x96; // fixed value

  // header checksum over 0xa0..0xbc
  var chk = 0;
  for (var a = 0xa0; a <= 0xbc; a++) {
    chk -= rom[a];
  }
  rom[0xbd] = (chk - 0x19) & 0xff;

  for (var i = 0; i < code.length; i++) {
    final w = code[i];
    rom[0xc0 + i * 4] = w & 0xff;
    rom[0xc0 + i * 4 + 1] = (w >> 8) & 0xff;
    rom[0xc0 + i * 4 + 2] = (w >> 16) & 0xff;
    rom[0xc0 + i * 4 + 3] = (w >> 24) & 0xff;
  }
  return rom;
}
