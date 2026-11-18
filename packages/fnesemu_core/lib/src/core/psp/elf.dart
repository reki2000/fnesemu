import 'dart:typed_data';

import 'memory.dart';

/// One imported library function: the library name and the name identifier
/// (a hash of the function name) from the module's stub table, plus the
/// address of its eight-byte stub. The kernel assigns each import a
/// syscall number and patches it into the stub's first word.
class PspImport {
  final String library;
  final int nid;
  final int stubAddr;
  int code = 0;
  PspImport(this.library, this.nid, this.stubAddr);
}

/// The result of loading a module into memory.
class PspModuleImage {
  final String name;
  final int entry;
  final int gp;
  final int base;

  /// The first address past the loaded segments, in user memory.
  final int end;
  final List<PspImport> imports;
  final List<({int start, int end})> segments;
  const PspModuleImage(
      this.name, this.entry, this.gp, this.base, this.end, this.imports,
      this.segments);
}

/// Loads the executable formats of the handheld: plain 32-bit little-endian
/// MIPS ELF files, relocatable module files (type 0xffa0, relocated against
/// a load base in user memory) and the PBP package format that wraps an ELF
/// in its data section. Relocations cover the word, jump and high/low pair
/// forms; the packed module relocation form is not supported.
class PspElf {
  static const _userBase = 0x08804000;

  static bool isElf(Uint8List body) =>
      body.length >= 4 &&
      body[0] == 0x7f &&
      body[1] == 0x45 &&
      body[2] == 0x4c &&
      body[3] == 0x46;

  static bool isPbp(Uint8List body) =>
      body.length >= 8 &&
      body[0] == 0 &&
      body[1] == 0x50 &&
      body[2] == 0x42 &&
      body[3] == 0x50;

  /// Whether an ELF carries the module info section every executable for
  /// this system has; other MIPS executables (for the ps2 core) do not,
  /// which keeps the two apart when a file is identified.
  static bool hasModuleInfo(Uint8List body) {
    if (!isElf(body) || body.length < 52) return false;
    final data = ByteData.sublistView(body);
    final shoff = data.getUint32(32, Endian.little);
    final shnum = data.getUint16(48, Endian.little);
    final shstrndx = data.getUint16(50, Endian.little);
    if (shoff == 0 || shstrndx >= shnum || shoff + shnum * 40 > body.length) {
      return false;
    }
    final strOff = data.getUint32(shoff + shstrndx * 40 + 16, Endian.little);
    const wanted = '.rodata.sceModuleInfo';
    for (var i = 0; i < shnum; i++) {
      final nameAt = strOff + data.getUint32(shoff + i * 40, Endian.little);
      if (nameAt + wanted.length >= body.length) continue;
      var match = true;
      for (var j = 0; j < wanted.length; j++) {
        if (body[nameAt + j] != wanted.codeUnitAt(j)) {
          match = false;
          break;
        }
      }
      if (match && body[nameAt + wanted.length] == 0) return true;
    }
    return false;
  }

  /// The executable bytes inside a PBP package.
  static Uint8List pbpExecutable(Uint8List body) {
    if (body.length < 40) throw const FormatException('Truncated PBP header');
    final data = ByteData.sublistView(body);
    final at = data.getUint32(32, Endian.little);
    final next = data.getUint32(36, Endian.little);
    final end = next > at ? next : body.length;
    if (at < 40 || at >= end || end > body.length) {
      throw const FormatException('PBP has no executable section');
    }
    return Uint8List.sublistView(body, at, end);
  }

  static PspModuleImage load(PspMemory mem, Uint8List body) {
    if (isPbp(body)) body = pbpExecutable(body);
    if (!isElf(body) || body.length < 52) {
      throw const FormatException('not an ELF executable');
    }
    final data = ByteData.sublistView(body);
    int u16(int at) => data.getUint16(at, Endian.little);
    int u32(int at) => data.getUint32(at, Endian.little);
    if (data.getUint8(4) != 1 || data.getUint8(5) != 1 || u16(18) != 8) {
      throw const FormatException('not a 32-bit little-endian MIPS ELF');
    }
    final type = u16(16);
    final entry = u32(24);
    final phoff = u32(28), shoff = u32(32);
    final phnum = u16(44), shnum = u16(48), shstrndx = u16(50);
    if (phoff + phnum * 32 > body.length ||
        shoff + shnum * 40 > body.length) {
      throw const FormatException('Truncated ELF header table');
    }

    var minVaddr = 0x7fffffff, maxEnd = 0;
    for (var i = 0; i < phnum; i++) {
      final at = phoff + i * 32;
      if (u32(at) != 1) continue;
      final vaddr = u32(at + 8), memsz = u32(at + 20);
      if (vaddr < minVaddr) minVaddr = vaddr;
      if (vaddr + memsz > maxEnd) maxEnd = vaddr + memsz;
    }
    if (minVaddr == 0x7fffffff) {
      throw const FormatException('ELF has no loadable segments');
    }
    final base = type == 0xffa0 || minVaddr < PspMemory.ramAt ? _userBase : 0;
    final segments = <({int start, int end})>[];

    for (var i = 0; i < phnum; i++) {
      final at = phoff + i * 32;
      if (u32(at) != 1) continue;
      final offset = u32(at + 4), vaddr = u32(at + 8) + base;
      final filesz = u32(at + 16), memsz = u32(at + 20);
      final phys = PspMemory.physical(vaddr);
      if (filesz > memsz || offset + filesz > body.length ||
          phys < PspMemory.ramAt || phys + memsz > PspMemory.ramEnd) {
        throw const FormatException('Invalid ELF load segment');
      }
      segments.add((start: phys, end: phys + memsz));
      mem.writeBytes(
          vaddr, Uint8List.sublistView(body, offset, offset + filesz));
      for (var j = filesz; j < memsz; j++) {
        mem.write8(vaddr + j, 0);
      }
    }

    // Section headers give the relocations and the module tables.
    String sectionName(int at) {
      if (shstrndx >= shnum) return '';
      final strAt = shoff + shstrndx * 40;
      final base = u32(strAt + 16) + u32(at + 0);
      final bytes = <int>[];
      for (var i = 0; body[base + i] != 0; i++) {
        bytes.add(body[base + i]);
      }
      return String.fromCharCodes(bytes);
    }

    var moduleInfoAt = -1;
    var stubTop = 0, stubEnd = 0;
    final relocState = _RelocState();
    for (var i = 0; i < shnum; i++) {
      final at = shoff + i * 40;
      final shType = u32(at + 4);
      final shAddr = u32(at + 12),
          shOffset = u32(at + 16),
          shSize = u32(at + 20);
      if (shType == 9 || shType == 0x700000a0) {
        _relocate(mem, body, shOffset, shSize, base, relocState);
      }
      final name = sectionName(at);
      if (name == '.rodata.sceModuleInfo') moduleInfoAt = shAddr + base;
      if (name == '.lib.stub') {
        stubTop = shAddr + base;
        stubEnd = stubTop + shSize;
      }
    }
    relocState.finish(mem, base);

    var gp = 0;
    var moduleName = '';
    if (moduleInfoAt >= 0) {
      gp = mem.read32(moduleInfoAt + 0x20);
      moduleName = mem.readString(moduleInfoAt + 4, 28);
      if (stubTop == 0) {
        stubTop = mem.read32(moduleInfoAt + 0x2c);
        stubEnd = mem.read32(moduleInfoAt + 0x30);
      }
    }

    final imports = <PspImport>[];
    var at = stubTop;
    while (at > 0 && at + 20 <= stubEnd) {
      final libPtr = mem.read32(at);
      final words = mem.read8(at + 8);
      final count = mem.read16(at + 10);
      final nidTable = mem.read32(at + 12);
      final stubTable = mem.read32(at + 16);
      if (libPtr == 0) break;
      final library = mem.readString(libPtr);
      for (var i = 0; i < count; i++) {
        imports.add(PspImport(
            library, mem.read32(nidTable + i * 4), stubTable + i * 8));
      }
      at += (words >= 5 ? words : 5) * 4;
    }
    return PspModuleImage(
        moduleName, entry + base, gp, base, maxEnd + base, imports, segments);
  }

  static void _relocate(PspMemory mem, Uint8List body, int offset,
      int size, int base, _RelocState state) {
    if (base == 0) return;
    final data = ByteData.sublistView(body);
    for (var at = offset; at + 8 <= offset + size; at += 8) {
      final rOffset = data.getUint32(at, Endian.little) + base;
      final rInfo = data.getUint32(at + 4, Endian.little);
      switch (rInfo & 0xff) {
        case 2: // word
          mem.write32(rOffset, mem.read32(rOffset) + base);
        case 4: // jump target field
          final word = mem.read32(rOffset);
          mem.write32(
              rOffset,
              (word & 0xfc000000) |
                  (((word & 0x3ffffff) + (base >> 2)) & 0x3ffffff));
        case 5: // high half (a lui): registers with the state, which
          // pairs it with the low halves that use its register.
          state.addHi(mem, rOffset, base);
        case 6: // low half
          state.addLo(mem, rOffset, base);
      }
    }
  }
}

/// Pairing state for the high/low half relocations of one module.
///
/// The relocation stream does not pair a high half (a lui) with its
/// low halves in any fixed order: several high halves can share one
/// low half where control flow merges, one high half serves many low
/// halves, and a low half can be listed before its high half. The
/// link between them is the register: a low half uses the register
/// its high half loads. High halves keep their original immediate
/// because completing a pair rewrites the word it came from.
class _RelocState {
  /// Every high half seen, as (location, immediate, destination
  /// register, paired) in stream order.
  final _his = <(int, int, int, bool)>[];

  /// Low halves seen before any matching high half, as (location,
  /// immediate, base register).
  final _earlyLos = <(int, int, int)>[];

  void _writePair(PspMemory mem, (int, int, int, bool) hi, int loAt,
      int loImm, int base) {
    final target = ((hi.$2 << 16) + loImm + base) & 0xffffffff;
    final hiWord = mem.read32(hi.$1), loWord = mem.read32(loAt);
    mem.write32(hi.$1,
        (hiWord & 0xffff0000) | (((target + 0x8000) >>> 16) & 0xffff));
    mem.write32(loAt, (loWord & 0xffff0000) | (target & 0xffff));
  }

  void addHi(PspMemory mem, int at, int base) {
    final word = mem.read32(at);
    final hi = (at, word & 0xffff, (word >> 16) & 31, false);
    _his.add(hi);
    // Low halves that arrived before this high half pair with it now.
    _earlyLos.removeWhere((lo) {
      if (lo.$3 != hi.$3) return false;
      _writePair(mem, hi, lo.$1, lo.$2, base);
      return true;
    });
  }

  void addLo(PspMemory mem, int at, int base) {
    final word = mem.read32(at);
    final rs = (word >> 21) & 31;
    final loImm = (word & 0xffff).toSigned(16);
    var paired = false;
    (int, int, int, bool)? latest;
    for (var i = 0; i < _his.length; i++) {
      final hi = _his[i];
      if (hi.$3 != rs) continue;
      latest = hi;
      if (!hi.$4) {
        _writePair(mem, hi, at, loImm, base);
        _his[i] = (hi.$1, hi.$2, hi.$3, true);
        paired = true;
      }
    }
    if (paired) return;
    if (latest != null) {
      // A shared high half serving one more low half.
      _writePair(mem, latest, at, loImm, base);
    } else {
      _earlyLos.add((at, loImm, rs));
    }
  }

  /// Relocates low halves whose high half never appeared (the high
  /// half is zero, e.g. an address formed from the gp register) on
  /// their own.
  void finish(PspMemory mem, int base) {
    for (final lo in _earlyLos) {
      final word = mem.read32(lo.$1);
      mem.write32(
          lo.$1, (word & 0xffff0000) | ((lo.$2 + base) & 0xffff));
    }
    _earlyLos.clear();
  }
}
