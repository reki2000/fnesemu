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

  // Aligned views of the three memories. The accessors below read and
  // write through them when the page tables resolve the address and the
  // address is aligned, which is much cheaper than the ByteData getters
  // and setters of the full path (see tool/dart_aot_tips.md).
  final Uint16List _ram16, _bios16, _scratch16;
  final Uint32List _ram32, _bios32, _scratch32;
  final Int64List _ram64, _bios64, _scratch64;

  IoPort? io;

  /// the TLB used for mapped segments, or null to map them to themselves
  Tlb? _tlb;

  Tlb? get tlb => _tlb;

  set tlb(Tlb? value) {
    _tlb = value;
    value?.onChange = _clearPages;
    _clearPages();
  }

  // Direct tables of the 4 KiB virtual pages that reach memory, for reads
  // and for writes. An entry is 0 when the page takes the full path, else
  // 1 + the offset of the page in [_ram], or in [_scratch] or [_bios] when
  // [_scratchPages] or [_biosPages] is added. They hold the result of the
  // TLB, so a TLB change clears them.
  static const _pageCount = 1 << 20;
  static const _scratchPages = 0x10000000, _biosPages = 0x20000000;
  final _readPages = Int32List(_pageCount);
  final _writePages = Int32List(_pageCount);
  final _filled = Int32List(4096);
  int _filledCount = 0;

  void _clearPages() {
    if (_filledCount > _filled.length) {
      _readPages.fillRange(0, _pageCount, 0);
      _writePages.fillRange(0, _pageCount, 0);
    } else {
      for (var i = 0; i < _filledCount; i++) {
        final page = _filled[i];
        _readPages[page] = 0;
        _writePages[page] = 0;
      }
    }
    _filledCount = 0;
  }

  /// records the page of [vaddr] after the full path found [region]
  void _remember(int vaddr, ByteData region, bool write) {
    final page = (vaddr >> 12) & (_pageCount - 1);
    final base = _offset & ~0xfff;
    final entry = 1 +
        (identical(region, _ram)
            ? base
            : identical(region, _scratch)
                ? _scratchPages + base
                : _biosPages + base);
    (write ? _writePages : _readPages)[page] = entry;
    if (_filledCount < _filled.length) _filled[_filledCount] = page;
    _filledCount++;
  }

  /// the memory of a page entry, with [_offset] set for [vaddr]
  ByteData _paged(int entry, int vaddr) {
    final o = entry - 1;
    if (o < _scratchPages) {
      _offset = o + (vaddr & 0xfff);
      return _ram;
    }
    if (o < _biosPages) {
      _offset = o - _scratchPages + (vaddr & 0xfff);
      return _scratch;
    }
    _offset = o - _biosPages + (vaddr & 0xfff);
    return _bios;
  }

  int unmappedAccesses = 0;
  int lastUnmappedAddress = 0;

  /// [ram] gives the main memory, such as a buffer shared with compiled
  /// code; it must hold [ramSize] bytes
  Ps2Bus({Uint8List? ram})
      : this._(ram ?? Uint8List(ramSize), Uint8List(biosSize),
            Uint8List(scratchSize));

  Ps2Bus._(this.ram, this.bios, this.scratch)
      : _ram = ByteData.sublistView(ram),
        _bios = ByteData.sublistView(bios),
        _scratch = ByteData.sublistView(scratch),
        _ram16 = Uint16List.view(ram.buffer, ram.offsetInBytes),
        _bios16 = Uint16List.view(bios.buffer, bios.offsetInBytes),
        _scratch16 = Uint16List.view(scratch.buffer, scratch.offsetInBytes),
        _ram32 = Uint32List.view(ram.buffer, ram.offsetInBytes),
        _bios32 = Uint32List.view(bios.buffer, bios.offsetInBytes),
        _scratch32 = Uint32List.view(scratch.buffer, scratch.offsetInBytes),
        _ram64 = Int64List.view(ram.buffer, ram.offsetInBytes),
        _bios64 = Int64List.view(bios.buffer, bios.offsetInBytes),
        _scratch64 = Int64List.view(scratch.buffer, scratch.offsetInBytes);

  /// Selects the memory a virtual address refers to. [offset] receives the
  /// offset inside it; null means no device is mapped there.
  ByteData? _region(int vaddr, bool write) {
    final entry =
        (write ? _writePages : _readPages)[(vaddr >> 12) & (_pageCount - 1)];
    if (entry != 0 && !_physical) return _paged(entry, vaddr);
    final r = _fullRegion(vaddr, write);
    if (r != null && !_physical) _remember(vaddr, r, write);
    return r;
  }

  ByteData? _fullRegion(int vaddr, bool write) {
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

  /// the region an aligned access resolved to through the page tables:
  /// 0 RAM, 1 scratchpad, 2 BIOS
  int _fastRegion = -1;

  /// When the page tables resolve [addr] without the TLB, sets [_offset]
  /// and [_fastRegion] and returns true. The caller checks the alignment
  /// of its access size, which also keeps the access inside the page.
  @pragma('vm:prefer-inline')
  bool _fastPaged(int addr, bool write) {
    if (_physical) return false;
    final entry =
        (write ? _writePages : _readPages)[(addr >> 12) & (_pageCount - 1)];
    if (entry == 0) return false;
    final o = entry - 1;
    if (o < _scratchPages) {
      _fastRegion = 0;
      _offset = o + (addr & 0xfff);
    } else if (o < _biosPages) {
      _fastRegion = 1;
      _offset = o - _scratchPages + (addr & 0xfff);
    } else {
      _fastRegion = 2;
      _offset = o - _biosPages + (addr & 0xfff);
    }
    return true;
  }

  /// reads or writes a quadword half at a physical address (DMA), bypassing
  /// the TLB
  int readPhysical64(int addr) {
    if (addr & 7 == 0) {
      if (addr >= 0 && addr + 8 <= ramSize) return _ram64[addr >> 3];
      final s = addr - scratchBase;
      if (s >= 0 && s + 8 <= scratchSize) return _scratch64[s >> 3];
    }
    _physical = true;
    final v = read64(addr);
    _physical = false;
    return v;
  }

  void writePhysical64(int addr, int value) {
    if (addr & 7 == 0) {
      if (addr >= 0 && addr + 8 <= ramSize) {
        _ram64[addr >> 3] = value;
        return;
      }
      final s = addr - scratchBase;
      if (s >= 0 && s + 8 <= scratchSize) {
        _scratch64[s >> 3] = value;
        return;
      }
    }
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
    if (_fastPaged(addr, false)) {
      return switch (_fastRegion) {
        0 => ram[_offset],
        1 => scratch[_offset],
        _ => bios[_offset],
      };
    }
    final r = _region(addr, false);
    return r == null ? _readIo(1) & 0xff : r.getUint8(_offset);
  }

  int read16(int addr) {
    if ((addr & 1) == 0 && _fastPaged(addr, false)) {
      return switch (_fastRegion) {
        0 => _ram16[_offset >> 1],
        1 => _scratch16[_offset >> 1],
        _ => _bios16[_offset >> 1],
      };
    }
    final r = _region(addr, false);
    return r == null
        ? _readIo(2) & 0xffff
        : r.getUint16(_offset, Endian.little);
  }

  int read32(int addr) {
    if ((addr & 3) == 0 && _fastPaged(addr, false)) {
      return switch (_fastRegion) {
        0 => _ram32[_offset >> 2],
        1 => _scratch32[_offset >> 2],
        _ => _bios32[_offset >> 2],
      };
    }
    final r = _region(addr, false);
    return r == null
        ? _readIo(4) & 0xffffffff
        : r.getUint32(_offset, Endian.little);
  }

  int read64(int addr) {
    if ((addr & 7) == 0 && _fastPaged(addr, false)) {
      return switch (_fastRegion) {
        0 => _ram64[_offset >> 3],
        1 => _scratch64[_offset >> 3],
        _ => _bios64[_offset >> 3],
      };
    }
    final r = _region(addr, false);
    return r == null ? _readIo(8) : r.getInt64(_offset, Endian.little);
  }

  void write8(int addr, int value) {
    if (_fastPaged(addr, true)) {
      switch (_fastRegion) {
        case 0:
          ram[_offset] = value;
        case 1:
          scratch[_offset] = value;
        default:
          bios[_offset] = value;
      }
      return;
    }
    final r = _region(addr, true);
    r == null ? _writeIo(1, value & 0xff) : r.setUint8(_offset, value);
  }

  void write16(int addr, int value) {
    if ((addr & 1) == 0 && _fastPaged(addr, true)) {
      switch (_fastRegion) {
        case 0:
          _ram16[_offset >> 1] = value;
        case 1:
          _scratch16[_offset >> 1] = value;
        default:
          _bios16[_offset >> 1] = value;
      }
      return;
    }
    final r = _region(addr, true);
    r == null
        ? _writeIo(2, value & 0xffff)
        : r.setUint16(_offset, value, Endian.little);
  }

  void write32(int addr, int value) {
    if ((addr & 3) == 0 && _fastPaged(addr, true)) {
      switch (_fastRegion) {
        case 0:
          _ram32[_offset >> 2] = value;
        case 1:
          _scratch32[_offset >> 2] = value;
        default:
          _bios32[_offset >> 2] = value;
      }
      return;
    }
    final r = _region(addr, true);
    r == null
        ? _writeIo(4, value & 0xffffffff)
        : r.setUint32(_offset, value, Endian.little);
  }

  void write64(int addr, int value) {
    if ((addr & 7) == 0 && _fastPaged(addr, true)) {
      switch (_fastRegion) {
        case 0:
          _ram64[_offset >> 3] = value;
        case 1:
          _scratch64[_offset >> 3] = value;
        default:
          _bios64[_offset >> 3] = value;
      }
      return;
    }
    final r = _region(addr, true);
    r == null ? _writeIo(8, value) : r.setInt64(_offset, value, Endian.little);
  }
}
