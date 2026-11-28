import 'dart:typed_data';

/// A two-pass mini assembler for the guest programs of the psp tests.
/// Only the encodings the tests use are provided.
class Asm {
  final words = <int>[];
  final _labels = <String, int>{};
  final _fixups = <int, (String, int)>{}; // word index -> (label, kind)
  int base;

  Asm(this.base);

  int get here => base + words.length * 4;

  void label(String name) => _labels[name] = here;
  int addr(String name) => _labels[name]!;

  void word(int w) => words.add(w & 0xffffffff);
  void r(int rs, int rt, int rd, int sa, int fn) =>
      word((rs << 21) | (rt << 16) | (rd << 11) | (sa << 6) | fn);
  void i(int op, int rs, int rt, int imm) =>
      word((op << 26) | (rs << 21) | (rt << 16) | (imm & 0xffff));
  void j(int op, int addr) => word((op << 26) | ((addr >> 2) & 0x3ffffff));

  void nop() => word(0);
  void lui(int rt, int imm) => i(0x0f, 0, rt, imm);
  void ori(int rt, int rs, int imm) => i(0x0d, rs, rt, imm);
  void addiu(int rt, int rs, int imm) => i(0x09, rs, rt, imm);
  void addi(int rt, int rs, int imm) => i(0x08, rs, rt, imm);
  void sw(int rt, int offset, int rs) => i(0x2b, rs, rt, offset);
  void lw(int rt, int offset, int rs) => i(0x23, rs, rt, offset);
  void sb(int rt, int offset, int rs) => i(0x28, rs, rt, offset);
  void lb(int rt, int offset, int rs) => i(0x20, rs, rt, offset);
  void lbu(int rt, int offset, int rs) => i(0x24, rs, rt, offset);
  void jal(int addr) => j(0x03, addr);
  void jr(int rs) => r(rs, 0, 0, 0, 0x08);
  void jalr(int rd, int rs) => r(rs, 0, rd, 0, 0x09);
  void syscall(int code) => word(0x0000000c | (code << 6));
  void branch(int op, int rs, int rt, String label) {
    _fixups[words.length] = (label, op == 0x04 ? 1 : 2);
    i(op, rs, rt, 0);
  }

  void beq(int rs, int rt, String label) => branch(0x04, rs, rt, label);
  void bne(int rs, int rt, String label) => branch(0x05, rs, rt, label);
  void jTo(String label) {
    _fixups[words.length] = (label, 3);
    j(0x02, 0);
  }

  void jalTo(String label) {
    _fixups[words.length] = (label, 3);
    j(0x03, 0);
  }

  /// Loads a 32-bit constant with the lui / ori pair.
  void li(int rt, int value) {
    if (value >= -0x8000 && value < 0x8000) {
      addiu(rt, 0, value);
    } else {
      lui(rt, (value >> 16) & 0xffff);
      ori(rt, rt, value & 0xffff);
    }
  }

  /// Loads the address of [label] with a lui / ori pair patched by
  /// [finish].
  void liAbs(int rt, String label) {
    _fixups[words.length] = (label, 4);
    lui(rt, 0);
    ori(rt, rt, 0);
  }

  List<int> finish() {
    for (final entry in _fixups.entries) {
      final (label, kind) = entry.value;
      final target = _labels[label]!;
      final at = base + entry.key * 4;
      if (kind == 4) {
        words[entry.key] = (words[entry.key] & 0xffff0000) | (target >>> 16);
        words[entry.key + 1] =
            (words[entry.key + 1] & 0xffff0000) | (target & 0xffff);
      } else if (kind == 3) {
        words[entry.key] =
            (words[entry.key] & 0xfc000000) | ((target >> 2) & 0x3ffffff);
      } else {
        final offset = (target - (at + 4)) >> 2;
        words[entry.key] = (words[entry.key] & 0xffff0000) | (offset & 0xffff);
      }
    }
    return words;
  }
}

/// Register numbers used by the test programs.
class Reg {
  static const zero = 0, at = 1, v0 = 2, v1 = 3;
  static const a0 = 4, a1 = 5, a2 = 6, a3 = 7;
  static const t0 = 8,
      t1 = 9,
      t2 = 10,
      t3 = 11,
      t4 = 12,
      t5 = 13,
      t6 = 14,
      t7 = 15;
  static const s0 = 16,
      s1 = 17,
      s2 = 18,
      s3 = 19,
      s4 = 20,
      s5 = 21,
      s6 = 22,
      s7 = 23;
  static const sp = 29, ra = 31;
}

/// The layout a [buildTestElf] produced, so tests can call the stubs and
/// find their data.
class TestElfLayout {
  final int entry;
  final int dataAt; // first address past the code, free for test data
  final Map<String, int> stubOf; // 'library/nid' -> stub address
  TestElfLayout(this.entry, this.dataAt, this.stubOf);
}

/// Builds a minimal ELF executable with one loadable segment:
///
/// ```
/// [code][module info][stub structs][nid tables][library names][stubs]
/// ```
///
/// The module info and stub tables follow the documented on-disk layout
/// the loader parses. With [prx] the file is a relocatable module (type
/// 0xffa0) linked at address zero, and [relocs] (segment offset, MIPS
/// relocation info) pairs are emitted in a relocation section. With
/// [secondSegmentAt] an empty second segment at that address follows,
/// for relocations relative to it.
(Uint8List, TestElfLayout) buildTestElf({
  required List<int> code,
  List<(String, List<int>)> imports = const [],
  bool prx = false,
  List<(int, int)> relocs = const [],
  String moduleName = 'test',
  int? secondSegmentAt,
}) {
  final base = prx ? 0 : 0x08800000;
  final seg = BytesBuilder();
  void put32(int v) {
    final b = ByteData(4)..setUint32(0, v & 0xffffffff, Endian.little);
    seg.add(b.buffer.asUint8List());
  }

  void put16(int v) {
    final b = ByteData(2)..setUint16(0, v & 0xffff, Endian.little);
    seg.add(b.buffer.asUint8List());
  }

  for (final w in code) {
    put32(w);
  }
  while (seg.length % 16 != 0) {
    seg.addByte(0);
  }
  final modinfoAt = base + seg.length;
  final stubStructsAt = modinfoAt + 52;
  var cursor = stubStructsAt + imports.length * 20;
  final nidTables = <int>[];
  for (final (_, nids) in imports) {
    nidTables.add(cursor);
    cursor += nids.length * 4;
  }
  final namePtrs = <int>[];
  for (final (lib, _) in imports) {
    namePtrs.add(cursor);
    cursor += lib.length + 1;
    while (cursor % 4 != 0) {
      cursor++;
    }
  }
  final stubTables = <int>[];
  for (final (_, nids) in imports) {
    stubTables.add(cursor);
    cursor += nids.length * 8;
  }
  final dataAt = cursor;

  // Module info (52 bytes): attribute, version, name, gp, the export
  // range (unused here) and the stub range.
  put16(0);
  put16(0x101);
  final nameBytes = moduleName.padRight(28, '\x00');
  for (var i = 0; i < 28; i++) {
    seg.addByte(nameBytes.codeUnitAt(i) & 0xff);
  }
  put32(0x08810000); // gp
  put32(0); // ent_top
  put32(0); // ent_end
  put32(stubStructsAt);
  put32(stubStructsAt + imports.length * 20);

  // Stub structs, nid tables, names, stub code.
  for (var li = 0; li < imports.length; li++) {
    put32(namePtrs[li]);
    put16(0x11); // version
    put16(0); // attribute
    seg.addByte(5); // entry size in words
    seg.addByte(0); // variable stub count
    put16(imports[li].$2.length);
    put32(nidTables[li]);
    put32(stubTables[li]);
  }
  for (final (_, nids) in imports) {
    for (final nid in nids) {
      put32(nid);
    }
  }
  for (final (lib, _) in imports) {
    seg.add(lib.codeUnits);
    seg.addByte(0);
    while (seg.length % 4 != 0) {
      seg.addByte(0);
    }
  }
  final stubOf = <String, int>{};
  for (var li = 0; li < imports.length; li++) {
    for (var fi = 0; fi < imports[li].$2.length; fi++) {
      stubOf['${imports[li].$1}/${imports[li].$2[fi]}'] = base + seg.length;
      put32(0x0000000c); // syscall 0, patched by the loader
      put32(0x03e00008); // jr ra
    }
  }
  final segBytes = seg.toBytes();

  // Sections: null, module info, stub, relocation (optional), names.
  final shstr = BytesBuilder();
  shstr.addByte(0);
  final offModinfo = shstr.length;
  shstr.add('.rodata.sceModuleInfo'.codeUnits);
  shstr.addByte(0);
  final offStub = shstr.length;
  shstr.add('.lib.stub'.codeUnits);
  shstr.addByte(0);
  final offRel = shstr.length;
  shstr.add('.rel.text'.codeUnits);
  shstr.addByte(0);
  final offShstr = shstr.length;
  shstr.add('.shstrtab'.codeUnits);
  shstr.addByte(0);
  final shstrBytes = shstr.toBytes();

  final relBytes = BytesBuilder();
  for (final (offset, type) in relocs) {
    final b = ByteData(8);
    b.setUint32(0, offset, Endian.little);
    b.setUint32(4, type, Endian.little);
    relBytes.add(b.buffer.asUint8List());
  }
  final relocData = relBytes.toBytes();

  final phnum = secondSegmentAt == null ? 1 : 2;
  final headerSize = 52 + 32 * phnum;
  final segOff = headerSize;
  final relOff = segOff + segBytes.length;
  final shstrOff = relOff + relocData.length;
  final shoff = (shstrOff + shstrBytes.length + 3) & ~3;

  final out = BytesBuilder();
  final eh = ByteData(52);
  eh.setUint8(0, 0x7f);
  eh.setUint8(1, 0x45);
  eh.setUint8(2, 0x4c);
  eh.setUint8(3, 0x46);
  eh.setUint8(4, 1);
  eh.setUint8(5, 1);
  eh.setUint8(6, 1);
  eh.setUint16(16, prx ? 0xffa0 : 2, Endian.little);
  eh.setUint16(18, 8, Endian.little);
  eh.setUint32(20, 1, Endian.little);
  eh.setUint32(24, base, Endian.little); // entry: the code starts the segment
  eh.setUint32(28, 52, Endian.little); // phoff
  eh.setUint32(32, shoff, Endian.little);
  eh.setUint16(40, 52, Endian.little);
  eh.setUint16(42, 32, Endian.little);
  eh.setUint16(44, phnum, Endian.little);
  eh.setUint16(46, 40, Endian.little);
  final shnum = relocs.isEmpty ? 4 : 5;
  eh.setUint16(48, shnum, Endian.little);
  eh.setUint16(50, shnum - 1, Endian.little); // shstrtab is last
  out.add(eh.buffer.asUint8List());
  final ph = ByteData(32);
  ph.setUint32(0, 1, Endian.little); // PT_LOAD
  ph.setUint32(4, segOff, Endian.little);
  ph.setUint32(8, base, Endian.little);
  ph.setUint32(12, base, Endian.little);
  ph.setUint32(16, segBytes.length, Endian.little);
  ph.setUint32(20, segBytes.length, Endian.little);
  ph.setUint32(24, 7, Endian.little);
  ph.setUint32(28, 0x1000, Endian.little);
  out.add(ph.buffer.asUint8List());
  if (secondSegmentAt != null) {
    final second = ByteData(32);
    second.setUint32(0, 1, Endian.little); // PT_LOAD, empty
    second.setUint32(4, segOff, Endian.little);
    second.setUint32(8, secondSegmentAt, Endian.little);
    second.setUint32(12, secondSegmentAt, Endian.little);
    second.setUint32(24, 6, Endian.little);
    second.setUint32(28, 0x10, Endian.little);
    out.add(second.buffer.asUint8List());
  }
  out.add(segBytes);
  out.add(relocData);
  out.add(shstrBytes);
  while (out.length < shoff) {
    out.addByte(0);
  }
  void section(int name, int type, int addr, int off, int size) {
    final sh = ByteData(40);
    sh.setUint32(0, name, Endian.little);
    sh.setUint32(4, type, Endian.little);
    sh.setUint32(12, addr, Endian.little);
    sh.setUint32(16, off, Endian.little);
    sh.setUint32(20, size, Endian.little);
    out.add(sh.buffer.asUint8List());
  }

  section(0, 0, 0, 0, 0);
  section(offModinfo, 1, modinfoAt, segOff + (modinfoAt - base), 52);
  section(offStub, 1, stubStructsAt, segOff + (stubStructsAt - base),
      imports.length * 20);
  if (relocs.isNotEmpty) {
    section(offRel, 0x700000a0, 0, relOff, relocData.length);
  }
  section(offShstr, 3, 0, shstrOff, shstrBytes.length);

  return (out.toBytes(), TestElfLayout(base, dataAt, stubOf));
}
