import 'dart:typed_data';

import 'r5900/tlb.dart';

/// Device registers in the 0x10000000..0x1fffffff range.
abstract class IoPort {
  bool handles(int address);

  /// reads a register of [size] bytes (4 for the usual word access)
  int read(int address, int size);

  /// returns false for an address without a register
  bool write(int address, int size, int value);
}

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

  IoPort? io;

  /// the TLB used for mapped segments, or null to map them to themselves
  Tlb? tlb;

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
    _ioAddress = -1;
    if (a >= scratchBase && a < scratchBase + scratchSize) {
      _offset = a - scratchBase;
      return _scratch;
    }
    int phys;
    if (a >= 0x80000000 && a < 0xc0000000) {
      phys = a & 0x1fffffff;
    } else {
      final t = _physical ? null : tlb;
      phys = t != null && t.active ? t.translate(a, write) : a;
    }
    if (phys < ramSize) {
      _offset = phys;
      return _ram;
    }
    if (!write && phys >= biosBase && phys < biosBase + biosSize) {
      _offset = phys - biosBase;
      return _bios;
    }
    if (phys >= 0x10000000 && phys < 0x20000000) {
      _ioAddress = phys;
      return null;
    }
    _unmapped(a);
    return null;
  }

  void _unmapped(int a) {
    unmappedAccesses++;
    lastUnmappedAddress = a;
  }

  int _offset = 0;
  int _ioAddress = -1;
  bool _physical = false;

  /// reads or writes a quadword half at a physical address (DMA), bypassing
  /// the TLB
  int readPhysical64(int addr) {
    _physical = true;
    final v = read64(addr);
    _physical = false;
    return v;
  }

  void writePhysical64(int addr, int value) {
    _physical = true;
    write64(addr, value);
    _physical = false;
  }

  int _readIo(int size) {
    final a = _ioAddress;
    _ioAddress = -1;
    final port = io;
    if (a < 0) return 0;
    if (port == null || !port.handles(a)) {
      _unmapped(a);
      return 0;
    }
    return port.read(a, size);
  }

  void _writeIo(int size, int value) {
    final a = _ioAddress;
    _ioAddress = -1;
    final port = io;
    if (a < 0) return;
    if (port == null || !port.write(a, size, value)) _unmapped(a);
  }

  int read8(int addr) {
    final r = _region(addr, false);
    return r == null ? _readIo(1) & 0xff : r.getUint8(_offset);
  }

  int read16(int addr) {
    final r = _region(addr, false);
    return r == null
        ? _readIo(2) & 0xffff
        : r.getUint16(_offset, Endian.little);
  }

  int read32(int addr) {
    final r = _region(addr, false);
    return r == null
        ? _readIo(4) & 0xffffffff
        : r.getUint32(_offset, Endian.little);
  }

  int read64(int addr) {
    final r = _region(addr, false);
    return r == null ? _readIo(8) : r.getInt64(_offset, Endian.little);
  }

  void write8(int addr, int value) {
    final r = _region(addr, true);
    r == null ? _writeIo(1, value & 0xff) : r.setUint8(_offset, value);
  }

  void write16(int addr, int value) {
    final r = _region(addr, true);
    r == null
        ? _writeIo(2, value & 0xffff)
        : r.setUint16(_offset, value, Endian.little);
  }

  void write32(int addr, int value) {
    final r = _region(addr, true);
    r == null
        ? _writeIo(4, value & 0xffffffff)
        : r.setUint32(_offset, value, Endian.little);
  }

  void write64(int addr, int value) {
    final r = _region(addr, true);
    r == null ? _writeIo(8, value) : r.setInt64(_offset, value, Endian.little);
  }
}
