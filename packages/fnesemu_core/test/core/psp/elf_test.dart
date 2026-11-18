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
