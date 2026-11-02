import 'dart:typed_data';

/// Optional 2 MiB RAM expansion accessed through four programmable ports.
///
/// The physical banks 0x40-0x43 mirror the four data ports. Registers live
/// in the I/O page at 0x1a00-0x1aff. The RAM is allocated on first access
/// and is not cleared by a soft reset.
class ArcadeCard {
  static const int ramSize = 2 * 1024 * 1024;
  static const int _ramMask = ramSize - 1;
  static const int _baseMask = 0xffffff;
  static const int _wordMask = 0xffff;
  static const int _longMask = 0xffffffff;

  final _ports = List.generate(4, (_) => _ArcadePort());
  Uint8List? _ram;
  int _shiftData = 0;
  int _shiftAmount = 0;
  int _rotateAmount = 0;

  Uint8List get _memory => _ram ??= Uint8List(ramSize);

  /// Reset the programmable registers without losing the RAM contents.
  void reset() {
    for (final port in _ports) {
      port.reset();
    }
    _shiftData = _shiftAmount = _rotateAmount = 0;
  }

  /// Clear the external RAM when the emulated machine is powered on.
  void powerOn() {
    _ram?.fillRange(0, ramSize, 0);
    reset();
  }

  int _offsetValue(_ArcadePort port) {
    final value = port.offset;
    return (port.control & 0x08) != 0 && (value & 0x8000) != 0
        ? value - 0x10000
        : value;
  }

  int _incrementValue(_ArcadePort port) {
    final value = port.increment;
    return (port.control & 0x04) != 0 && (value & 0x8000) != 0
        ? value - 0x10000
        : value;
  }

  int _address(_ArcadePort port) {
    final offset = (port.control & 0x02) != 0 ? _offsetValue(port) : 0;
    return (port.base + offset) & _ramMask;
  }

  void _advance(_ArcadePort port) {
    if ((port.control & 0x01) == 0) return;
    if ((port.control & 0x10) != 0) {
      port.base = (port.base + _incrementValue(port)) & _baseMask;
    } else {
      port.offset = (port.offset + port.increment) & _wordMask;
    }
  }

  void _addOffset(_ArcadePort port) {
    port.base = (port.base + _offsetValue(port)) & _baseMask;
  }

  /// Data register for a physical bank (0 through 3).
  int readData(int index) {
    final port = _ports[index];
    final result = _memory[_address(port)];
    _advance(port);
    return result;
  }

  void writeData(int index, int value) {
    final port = _ports[index];
    _memory[_address(port)] = value & 0xff;
    _advance(port);
  }

  /// Read a register in the I/O page, specified by its 13-bit offset.
  int read(int address) {
    final reg = address & 0xff;
    if (reg < 0x80) {
      final port = _ports[(reg >> 4) & 3];
      switch (reg & 0x0f) {
        case 0:
        case 1:
          return readData((reg >> 4) & 3);
        case 2:
          return port.base & 0xff;
        case 3:
          return (port.base >> 8) & 0xff;
        case 4:
          return (port.base >> 16) & 0xff;
        case 5:
          return port.offset & 0xff;
        case 6:
          return (port.offset >> 8) & 0xff;
        case 7:
          return port.increment & 0xff;
        case 8:
          return (port.increment >> 8) & 0xff;
        case 9:
          return port.control;
      }
    } else if (reg >= 0xe0) {
      if (reg <= 0xe3) {
        return (_shiftData >> ((reg & 3) * 8)) & 0xff;
      }
      switch (reg) {
        case 0xe4:
          return _shiftAmount;
        case 0xe5:
          return _rotateAmount;
        case 0xec:
        case 0xed:
          return 0;
        case 0xfe:
          return 0x10;
        case 0xff:
          return 0x51;
      }
    }
    return 0xff;
  }

  /// Write a register in the I/O page, specified by its 13-bit offset.
  void write(int address, int value) {
    value &= 0xff;
    final reg = address & 0xff;
    if (reg < 0x80) {
      final port = _ports[(reg >> 4) & 3];
      switch (reg & 0x0f) {
        case 0:
        case 1:
          writeData((reg >> 4) & 3, value);
          break;
        case 2:
          port.base = (port.base & 0xffff00) | value;
          break;
        case 3:
          port.base = (port.base & 0xff00ff) | (value << 8);
          break;
        case 4:
          port.base = (port.base & 0x00ffff) | (value << 16);
          break;
        case 5:
          port.offset = (port.offset & 0xff00) | value;
          if ((port.control & 0x60) == 0x20) _addOffset(port);
          break;
        case 6:
          port.offset = (port.offset & 0x00ff) | (value << 8);
          if ((port.control & 0x60) == 0x40) _addOffset(port);
          break;
        case 7:
          port.increment = (port.increment & 0xff00) | value;
          break;
        case 8:
          port.increment = (port.increment & 0x00ff) | (value << 8);
          break;
        case 9:
          port.control = value & 0x7f;
          break;
        case 10:
          if ((port.control & 0x60) == 0x60) _addOffset(port);
          break;
      }
    } else if (reg >= 0xe0) {
      if (reg <= 0xe3) {
        final shift = (reg & 3) * 8;
        _shiftData =
            ((_shiftData & ~(0xff << shift)) | (value << shift)) & _longMask;
      } else if (reg == 0xe4) {
        _shiftAmount = value;
        final bits = value & 0x0f;
        if (bits != 0) {
          _shiftData = bits < 8
              ? (_shiftData << bits) & _longMask
              : _shiftData >> (16 - bits);
        }
      } else if (reg == 0xe5) {
        _rotateAmount = value;
        final bits = value & 0x0f;
        if (bits != 0) {
          final left = bits < 8 ? bits : bits - 16;
          final shift = left < 0 ? left + 32 : left;
          _shiftData = ((_shiftData << shift) | (_shiftData >> (32 - shift))) &
              _longMask;
        }
      }
    }
  }
}

class _ArcadePort {
  int base = 0;
  int offset = 0;
  int increment = 0;
  int control = 0;

  void reset() {
    base = offset = increment = control = 0;
  }
}
