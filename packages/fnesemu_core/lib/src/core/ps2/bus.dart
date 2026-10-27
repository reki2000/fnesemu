import 'dart:typed_data';

/// Physical memory map of the EE as seen by the R5900.
///
/// Only main memory, the scratchpad and the boot ROM are mapped. The TLB is
/// not implemented yet: user and mapped segments are treated as physical
/// addresses. Accesses to anything else read as zero and are counted in
/// [unmappedAccesses].
class Ps2Bus {
  static const ramSize = 32 * 1024 * 1024;
  static const biosBase = 0x1fc00000;
  static const biosSize = 4 * 1024 * 1024;
  static const scratchBase = 0x70000000;
  static const scratchSize = 16 * 1024;

  final Uint8List ram;
  final Uint8List bios;
  final Uint8List scratch;
  final ByteData _ram, _bios, _scratch;

  int unmappedAccesses = 0;
  int lastUnmappedAddress = 0;

  Ps2Bus()
      : this._(Uint8List(ramSize), Uint8List(biosSize), Uint8List(scratchSize));

  Ps2Bus._(this.ram, this.bios, this.scratch)
      : _ram = ByteData.view(ram.buffer),
        _bios = ByteData.view(bios.buffer),
        _scratch = ByteData.view(scratch.buffer);

  /// Selects the memory a virtual address refers to. [offset] receives the
  /// offset inside it; null means no device is mapped there.
  ByteData? _region(int vaddr, bool write) {
    final a = vaddr & 0xffffffff;
    if (a >= scratchBase && a < scratchBase + scratchSize) {
      _offset = a - scratchBase;
      return _scratch;
    }
    final phys = a >= 0x80000000 && a < 0xc0000000 ? a & 0x1fffffff : a;
    if (phys < ramSize) {
      _offset = phys;
      return _ram;
    }
    if (!write && phys >= biosBase && phys < biosBase + biosSize) {
      _offset = phys - biosBase;
      return _bios;
    }
    unmappedAccesses++;
    lastUnmappedAddress = a;
    return null;
  }

  int _offset = 0;

  int read8(int addr) {
    final r = _region(addr, false);
    return r == null ? 0 : r.getUint8(_offset);
  }

  int read16(int addr) {
    final r = _region(addr, false);
    return r == null ? 0 : r.getUint16(_offset, Endian.little);
  }

  int read32(int addr) {
    final r = _region(addr, false);
    return r == null ? 0 : r.getUint32(_offset, Endian.little);
  }

  int read64(int addr) {
    final r = _region(addr, false);
    return r == null ? 0 : r.getInt64(_offset, Endian.little);
  }

  void write8(int addr, int value) =>
      _region(addr, true)?.setUint8(_offset, value);

  void write16(int addr, int value) =>
      _region(addr, true)?.setUint16(_offset, value, Endian.little);

  void write32(int addr, int value) =>
      _region(addr, true)?.setUint32(_offset, value, Endian.little);

  void write64(int addr, int value) =>
      _region(addr, true)?.setInt64(_offset, value, Endian.little);
}
