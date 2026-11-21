import 'dart:typed_data';

import 'package:fnesemu_core/src/core/psp/elf.dart';
import 'package:fnesemu_core/src/core/psp/memory.dart';
import 'package:test/test.dart';

import 'fixture.dart';

void main() {
  test('an exec ELF loads its segment and parses the import stubs', () {
    final (bytes, layout) = buildTestElf(
      code: [0x00000000, 0x03e00008],
      imports: [
        ('sceDisplay', [0x289d82fe, 0x984c27e7]),
        ('ThreadManForUser', [0x446d8de6]),
      ],
    );
    final mem = PspMemory();
    final image = PspElf.load(mem, bytes);
    expect(image.entry, 0x08800000);
    expect(image.base, 0);
    expect(image.name, 'test');
    expect(image.gp, 0x08810000);
    expect(mem.read32(0x08800000), 0);
    expect(mem.read32(0x08800004), 0x03e00008);
    expect(image.imports.length, 3);
    expect(image.imports[0].library, 'sceDisplay');
    expect(image.imports[0].nid, 0x289d82fe);
    expect(
        image.imports[0].stubAddr, layout.stubOf['sceDisplay/${0x289d82fe}']);
    expect(image.imports[2].library, 'ThreadManForUser');
    expect(image.end, layout.dataAt);
  });

  test('a prx module relocates against its load base', () {
    // Segment content: a word holding a pointer to itself (offset 0) and
    // a lui / addiu pair forming the same pointer at offsets 8 and 12.
    final target = 0x08804000; // where offset 0 lands after relocation
    final code = <int>[
      0x00000000, // patched below: the pointer word itself
      0,
      (0x0f << 26) | (8 << 16) | ((0 >> 16) & 0xffff), // lui t0, hi(0)
      (0x09 << 26) | (8 << 21) | (8 << 16) | 0, // addiu t0, t0, lo(0)
    ];
    final (bytes, _) = buildTestElf(
      code: code,
      prx: true,
      relocs: [(0, 2), (8, 5), (12, 6)],
    );
    final mem = PspMemory();
    final image = PspElf.load(mem, bytes);
    expect(image.base, 0x08804000);
    expect(image.entry, target);
    expect(mem.read32(target), target); // R_MIPS_32 added the base
    final hi = mem.read32(target + 8) & 0xffff;
    final lo = (mem.read32(target + 12) & 0xffff).toSigned(16);
    expect((hi << 16) + lo, target); // the pair still forms the pointer
  });

  test('a later low half of another segment leaves a pair intact', () {
    // The a0 pair at 0 and 4 refers to the second segment, at 0x20000. A
    // later low half on a0 refers to the first segment; it must not
    // rewrite the high half of the pair.
    final code = <int>[
      (0x0f << 26) | (4 << 16) | 0, // lui a0, 0
      (0x23 << 26) | (4 << 21) | (4 << 16) | 0x20, // lw a0, 0x20(a0)
      (0x23 << 26) | (4 << 21) | (4 << 16) | 0x4, // lw a0, 4(a0)
      0,
      0,
    ];
    final (bytes, _) = buildTestElf(
      code: code,
      prx: true,
      secondSegmentAt: 0x20000,
      relocs: [(0, 5 | 1 << 16), (4, 6 | 1 << 16), (8, 6)],
    );
    final mem = PspMemory();
    PspElf.load(mem, bytes);
    const base = 0x08804000;
    final hi = mem.read32(base) & 0xffff;
    final lo = (mem.read32(base + 4) & 0xffff).toSigned(16);
    expect((hi << 16) + lo, base + 0x20000 + 0x20);
  });

  test('a jump relocation shifts the target field', () {
    final code = <int>[
      (0x02 << 26) | (0x10 >> 2), // j 0x10 (segment relative)
      0,
    ];
    final (bytes, _) = buildTestElf(code: code, prx: true, relocs: [(0, 4)]);
    final mem = PspMemory();
    PspElf.load(mem, bytes);
    final word = mem.read32(0x08804000);
    expect((word & 0x3ffffff) << 2, 0x10 + 0x08804000);
  });

  test('a relocation follows the segments its info names', () {
    // The second segment starts at 8. The pair at 0 and the word at 8
    // refer to offset 0x28 of it, 0x30; the word at 12 is listed at
    // offset 4 of it.
    final code = <int>[
      (0x0f << 26) | (8 << 16) | 0, // lui t0, 0
      (0x09 << 26) | (8 << 21) | (8 << 16) | 0x28, // addiu t0, t0, 0x28
      0x28,
      0x30,
    ];
    final (bytes, _) = buildTestElf(
      code: code,
      prx: true,
      secondSegmentAt: 8,
      relocs: [
        (0, 5 | 1 << 16),
        (4, 6 | 1 << 16),
        (8, 2 | 1 << 16),
        (4, 2 | 1 << 8),
      ],
    );
    final mem = PspMemory();
    PspElf.load(mem, bytes);
    const base = 0x08804000;
    final hi = mem.read32(base) & 0xffff;
    final lo = (mem.read32(base + 4) & 0xffff).toSigned(16);
    expect((hi << 16) + lo, base + 0x30);
    expect(mem.read32(base + 8), base + 0x30);
    expect(mem.read32(base + 12), base + 0x30);
  });

  test('a relocation naming a missing segment is rejected', () {
    final (bytes, _) =
        buildTestElf(code: [0], prx: true, relocs: [(0, 2 | 1 << 16)]);
    expect(() => PspElf.load(PspMemory(), bytes), throwsFormatException);
  });

  test('pbp packages unwrap to their executable', () {
    final (elf, _) = buildTestElf(code: [0x03e00008]);
    final pbp = Uint8List(40 + elf.length);
    pbp[1] = 0x50; // 'P'
    pbp[2] = 0x42; // 'B'
    pbp[3] = 0x50; // 'P'
    final data = ByteData.sublistView(pbp);
    data.setUint32(32, 40, Endian.little); // the executable offset
    data.setUint32(36, 40 + elf.length, Endian.little);
    pbp.setAll(40, elf);
    expect(PspElf.isPbp(pbp), isTrue);
    final mem = PspMemory();
    final image = PspElf.load(mem, pbp);
    expect(image.entry, 0x08800000);
    expect(mem.read32(0x08800000), 0x03e00008);
  });

  test('non executables are rejected', () {
    final mem = PspMemory();
    expect(() => PspElf.load(mem, Uint8List.fromList([1, 2, 3, 4])),
        throwsFormatException);
  });
}
