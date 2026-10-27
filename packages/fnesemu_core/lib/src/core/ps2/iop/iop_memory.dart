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

  final Uint8List ram = Uint8List(ramSize);
  final Uint8List scratch = Uint8List(scratchSize);
  final Uint8List bios;
  late final ByteData _ram = ByteData.view(ram.buffer);
  late final ByteData _scratch = ByteData.view(scratch.buffer);
  late final ByteData _bios = ByteData.view(bios.buffer);

  IopPort? port;

  IopMemory(this.bios);

  /// the memory a physical address falls in, and the offset inside it
  (ByteData, int)? _locate(int address, bool write) {
    final phys = address & 0x1fffffff;
    if (phys < 0x00800000) return (_ram, phys & (ramSize - 1));
    if (phys >= biosBase) {
      if (write) return null;
      return (_bios, (phys - biosBase) & (bios.length - 1));
    }
    if (phys >= scratchBase && phys < scratchBase + scratchSize) {
      return (_scratch, phys - scratchBase);
    }
    return null;
  }

  @override
  int read8(int a) {
    final m = _locate(a, false);
    if (m != null) return m.$1.getUint8(m.$2);
    return port?.read(a & 0x1fffffff, 1) ?? 0;
  }

  @override
  int read16(int a) {
    final m = _locate(a, false);
    if (m != null) return m.$1.getUint16(m.$2, Endian.little);
    return port?.read(a & 0x1fffffff, 2) ?? 0;
  }

  @override
  int read32(int a) {
    final m = _locate(a, false);
    if (m != null) return m.$1.getUint32(m.$2, Endian.little);
    return port?.read(a & 0x1fffffff, 4) ?? 0;
  }

  @override
  void write8(int a, int v) {
    final m = _locate(a, true);
    if (m != null) {
      m.$1.setUint8(m.$2, v);
    } else {
      port?.write(a & 0x1fffffff, 1, v & 0xff);
    }
  }

  @override
  void write16(int a, int v) {
    final m = _locate(a, true);
    if (m != null) {
      m.$1.setUint16(m.$2, v, Endian.little);
    } else {
      port?.write(a & 0x1fffffff, 2, v & 0xffff);
    }
  }

  @override
  void write32(int a, int v) {
    final m = _locate(a, true);
    if (m != null) {
      m.$1.setUint32(m.$2, v, Endian.little);
    } else {
      port?.write(a & 0x1fffffff, 4, v & 0xffffffff);
    }
  }
}
