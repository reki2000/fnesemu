import 'dart:typed_data';

/// The physical memory map of the handheld: a 16 KiB scratchpad, 2 MiB of
/// video memory and 32 MiB of main memory. Every virtual mirror of the map
/// (the direct space, the cached mirror at 0x40000000, the uncached one at
/// 0x60000000 and the kernel segments above them) masks down to the same
/// physical addresses, so translation is a single mask. Unmapped accesses
/// read as zero and drop writes, which keeps stray kernel probes from
/// stopping execution.
class PspMemory {
  static const scratchAt = 0x00010000;
  static const scratchSize = 0x4000;
  static const vramAt = 0x04000000;
  static const vramSize = 0x200000;
  static const ramAt = 0x08000000;
  static const ramSize = 0x2000000;
  static const ramEnd = ramAt + ramSize;

  final scratch = Uint8List(scratchSize);
  final vram = Uint8List(vramSize);
  final ram = Uint8List(ramSize);
  late final ByteData _scratchData = ByteData.sublistView(scratch);
  late final ByteData _vramData = ByteData.sublistView(vram);
  late final ByteData _ramData = ByteData.sublistView(ram);

  void clear() {
    scratch.fillRange(0, scratch.length, 0);
    vram.fillRange(0, vram.length, 0);
    ram.fillRange(0, ram.length, 0);
  }

  /// The physical address behind a virtual one: all mirrors of this
  /// machine's fixed map differ only in the top three bits.
  static int physical(int addr) => addr & 0x1fffffff;

  (ByteData, int) _region(int phys) {
    if (phys >= ramAt && phys < ramEnd) return (_ramData, phys - ramAt);
    if (phys >= vramAt && phys < vramAt + vramSize) {
      return (_vramData, phys - vramAt);
    }
    if (phys >= scratchAt && phys < scratchAt + scratchSize) {
      return (_scratchData, phys - scratchAt);
    }
    return (_ramData, -1);
  }

  int read8(int addr) {
    final (data, at) = _region(physical(addr));
    return at < 0 ? 0 : data.getUint8(at);
  }

  int read16(int addr) {
    final (data, at) = _region(physical(addr));
    if (at < 0 || at + 1 >= data.lengthInBytes) return 0;
    return data.getUint16(at, Endian.little);
  }

  int read32(int addr) {
    final (data, at) = _region(physical(addr));
    if (at < 0 || at + 3 >= data.lengthInBytes) return 0;
    return data.getUint32(at, Endian.little);
  }

  void write8(int addr, int value) {
    final (data, at) = _region(physical(addr));
    if (at >= 0) data.setUint8(at, value & 0xff);
  }

  void write16(int addr, int value) {
    final (data, at) = _region(physical(addr));
    if (at >= 0 && at + 1 < data.lengthInBytes) {
      data.setUint16(at, value & 0xffff, Endian.little);
    }
  }

  void write32(int addr, int value) {
    final (data, at) = _region(physical(addr));
    if (at >= 0 && at + 3 < data.lengthInBytes) {
      data.setUint32(at, value, Endian.little);
    }
  }

  /// A byte view of a region for bulk transfers; [phys] must be the start
  /// of the region and the length must fit inside it.
  Uint8List view(int phys, int length) {
    if (phys >= ramAt && phys + length <= ramEnd) {
      return Uint8List.sublistView(ram, phys - ramAt, phys - ramAt + length);
    }
    if (phys >= vramAt && phys + length <= vramAt + vramSize) {
      return Uint8List.sublistView(vram, phys - vramAt, phys - vramAt + length);
    }
    if (phys >= scratchAt && phys + length <= scratchAt + scratchSize) {
      return Uint8List.sublistView(
          scratch, phys - scratchAt, phys - scratchAt + length);
    }
    throw ArgumentError('no region at 0x${phys.toRadixString(16)}');
  }

  /// Copies guest bytes out for the loader and state code; unmapped parts
  /// read as zero.
  Uint8List readBytes(int addr, int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = read8(addr + i);
    }
    return out;
  }

  void writeBytes(int addr, List<int> bytes, [int offset = 0]) {
    for (var i = 0; i < bytes.length; i++) {
      write8(addr + i, bytes[offset + i]);
    }
  }

  String readString(int addr, [int max = 256]) {
    final bytes = <int>[];
    for (var i = 0; i < max; i++) {
      final b = read8(addr + i);
      if (b == 0) break;
      bytes.add(b);
    }
    return String.fromCharCodes(bytes);
  }
}
