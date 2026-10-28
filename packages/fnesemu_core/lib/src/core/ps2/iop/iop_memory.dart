import 'dart:typed_data';

import 'iop.dart';

/// The peripherals of the IOP address space outside RAM, the scratchpad and
/// the BIOS ROM.
abstract class IopPort {
  int read(int address, int size);
  void write(int address, int size, int value);
}

/// The IOP memory map. The BIOS ROM is the same image the EE sees.
class IopMemory implements IopBus {
  static const ramSize = 2 * 1024 * 1024;
  static const scratchBase = 0x1f800000, scratchSize = 1024;
  static const biosBase = 0x1fc00000;

  final Uint8List ram;
  final Uint8List scratch;
  final Uint8List bios;
  final ByteData _ram, _scratch, _bios;

  IopPort? port;

  IopMemory(Uint8List bios)
      : this._(Uint8List(ramSize), Uint8List(scratchSize), bios);

  IopMemory._(this.ram, this.scratch, this.bios)
      : _ram = ByteData.sublistView(ram),
        _scratch = ByteData.sublistView(scratch),
        _bios = ByteData.sublistView(bios);

  /// the offset inside the memory that [_locate] returned
  int _offset = 0;

  /// the memory outside RAM that a physical address falls in; the offset
  /// inside it goes to [_offset]
  ByteData? _locate(int phys, bool write) {
    if (phys >= biosBase) {
      if (write) return null;
      _offset = (phys - biosBase) & (bios.length - 1);
      return _bios;
    }
    if (phys >= scratchBase && phys < scratchBase + scratchSize) {
      _offset = phys - scratchBase;
      return _scratch;
    }
    return null;
  }

  @override
  int read8(int a) {
    final phys = a & 0x1fffffff;
    if (phys < 0x00800000) return ram[phys & (ramSize - 1)];
    final m = _locate(phys, false);
    if (m != null) return m.getUint8(_offset);
    return port?.read(phys, 1) ?? 0;
  }

  @override
  int read16(int a) {
    final phys = a & 0x1fffffff;
    if (phys < 0x00800000) {
      return _ram.getUint16(phys & (ramSize - 1), Endian.little);
    }
    final m = _locate(phys, false);
    if (m != null) return m.getUint16(_offset, Endian.little);
    return port?.read(phys, 2) ?? 0;
  }

  @override
  int read32(int a) {
    final phys = a & 0x1fffffff;
    if (phys < 0x00800000) {
      return _ram.getUint32(phys & (ramSize - 1), Endian.little);
    }
    final m = _locate(phys, false);
    if (m != null) return m.getUint32(_offset, Endian.little);
    return port?.read(phys, 4) ?? 0;
  }

  @override
  void write8(int a, int v) {
    final phys = a & 0x1fffffff;
    if (phys < 0x00800000) {
      ram[phys & (ramSize - 1)] = v;
      return;
    }
    final m = _locate(phys, true);
    if (m != null) {
      m.setUint8(_offset, v);
    } else {
      port?.write(phys, 1, v & 0xff);
    }
  }

  @override
  void write16(int a, int v) {
    final phys = a & 0x1fffffff;
    if (phys < 0x00800000) {
      _ram.setUint16(phys & (ramSize - 1), v, Endian.little);
      return;
    }
    final m = _locate(phys, true);
    if (m != null) {
      m.setUint16(_offset, v, Endian.little);
    } else {
      port?.write(phys, 2, v & 0xffff);
    }
  }

  @override
  void write32(int a, int v) {
    final phys = a & 0x1fffffff;
    if (phys < 0x00800000) {
      _ram.setUint32(phys & (ramSize - 1), v, Endian.little);
      return;
    }
    final m = _locate(phys, true);
    if (m != null) {
      m.setUint32(_offset, v, Endian.little);
    } else {
      port?.write(phys, 4, v & 0xffffffff);
    }
  }
}
