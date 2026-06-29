import 'dart:typed_data';

import '../sram.dart';

/// Cartridge backup memory kind, auto-detected from identifier strings the
/// developer tools embed in the ROM.
enum BackupType { none, sram, flash512, flash1m, eeprom }

/// GBA backup memory: SRAM, Flash (64/128KB) or EEPROM (512B/8KB), persisted
/// through the host [Sram] storage so saves survive across sessions.
class Backup {
  BackupType type = BackupType.none;
  late Sram storage;

  _Flash? _flash;
  _Eeprom? _eeprom;

  bool get isEeprom => type == BackupType.eeprom;

  /// scan the ROM for the well-known backup identifier strings.
  static BackupType detect(Uint8List rom) {
    bool has(String s) => _contains(rom, s);
    if (has("EEPROM_V")) return BackupType.eeprom;
    if (has("FLASH1M_V")) return BackupType.flash1m;
    if (has("FLASH512_V") || has("FLASH_V")) return BackupType.flash512;
    if (has("SRAM_V") || has("SRAM_F_V")) return BackupType.sram;
    return BackupType.none;
  }

  static bool _contains(Uint8List rom, String needle) {
    final n = needle.codeUnits;
    final limit = rom.length - n.length;
    for (int i = 0; i <= limit; i++) {
      bool ok = true;
      for (int j = 0; j < n.length; j++) {
        if (rom[i + j] != n[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return true;
    }
    return false;
  }

  /// size and load the persistent storage for the detected [type].
  void init(BackupType type, Sram storage, String id) {
    this.type = type;
    this.storage = storage;
    _flash = null;
    _eeprom = null;

    switch (type) {
      case BackupType.none:
        storage.init(id, Uint8List(0));
        break;
      case BackupType.sram:
        storage.init(id, Uint8List(0x8000)); // 32KB
        break;
      case BackupType.flash512:
        storage.init("$id.fl", Uint8List(0x10000)..fillRange(0, 0x10000, 0xff));
        _flash = _Flash(storage, banks: 1);
        break;
      case BackupType.flash1m:
        storage.init(
            "$id.fl", Uint8List(0x20000)..fillRange(0, 0x20000, 0xff));
        _flash = _Flash(storage, banks: 2);
        break;
      case BackupType.eeprom:
        storage.init("$id.ee", Uint8List(0x2000)); // 8KB covers both sizes
        _eeprom = _Eeprom(storage);
        break;
    }
  }

  // --- region 0x0E/0x0F (SRAM / Flash, 8-bit bus) ---------------------------

  int read8(int offset) {
    switch (type) {
      case BackupType.sram:
        return storage.read8(offset & 0x7fff);
      case BackupType.flash512:
      case BackupType.flash1m:
        return _flash!.read8(offset & 0xffff);
      default:
        return 0xff;
    }
  }

  void write8(int offset, int data) {
    switch (type) {
      case BackupType.sram:
        storage.write8(offset & 0x7fff, data & 0xff);
        return;
      case BackupType.flash512:
      case BackupType.flash1m:
        _flash!.write8(offset & 0xffff, data & 0xff);
        return;
      default:
        return;
    }
  }

  // --- region 0x0D (EEPROM serial) ------------------------------------------

  /// called by DMA before an EEPROM command stream so the address width can be
  /// inferred from the transfer length.
  void eepromBeginCommand(int count) => _eeprom?.beginCommand(count);
  int eepromRead() => _eeprom?.readBit() ?? 1;
  void eepromWrite(int bit) => _eeprom?.writeBit(bit);
}

/// Flash command state machine (Atmel/Macronix style AA/55 sequences).
class _Flash {
  final Sram storage;
  final int banks; // 1 = 64KB, 2 = 128KB
  _Flash(this.storage, {required this.banks});

  int _bank = 0;
  int _phase = 0;
  bool _idMode = false;
  bool _eraseArmed = false;
  bool _writeArmed = false;
  bool _bankArmed = false;

  // identification bytes (manufacturer, device).
  int get _manufacturer => banks == 2 ? 0x62 : 0x32; // Sanyo 128K / Panasonic 64K
  int get _device => banks == 2 ? 0x13 : 0x1b;

  int _index(int addr) => _bank * 0x10000 + (addr & 0xffff);

  int read8(int addr) {
    if (_idMode) {
      if ((addr & 0xffff) == 0) return _manufacturer;
      if ((addr & 0xffff) == 1) return _device;
    }
    return storage.read8(_index(addr));
  }

  void write8(int addr, int data) {
    addr &= 0xffff;

    if (_writeArmed) {
      storage.write8(_index(addr), data);
      _writeArmed = false;
      return;
    }
    if (_bankArmed) {
      _bank = (banks == 2) ? (data & 1) : 0;
      _bankArmed = false;
      return;
    }

    switch (_phase) {
      case 0:
        if (addr == 0x5555 && data == 0xaa) _phase = 1;
        return;
      case 1:
        _phase = (addr == 0x2aaa && data == 0x55) ? 2 : 0;
        return;
      case 2:
        _phase = 0;
        _command(addr, data);
        return;
    }
  }

  void _command(int addr, int data) {
    if (addr == 0x5555) {
      switch (data) {
        case 0x90:
          _idMode = true;
          return;
        case 0xf0:
          _idMode = false;
          return;
        case 0x80:
          _eraseArmed = true;
          return;
        case 0xa0:
          _writeArmed = true;
          return;
        case 0xb0:
          _bankArmed = true;
          return;
        case 0x10:
          if (_eraseArmed) {
            for (int i = 0; i < banks * 0x10000; i++) {
              storage.write8(i, 0xff);
            }
            _eraseArmed = false;
          }
          return;
      }
    }
    // sector erase: 0x30 at the sector address (4KB sectors).
    if (data == 0x30 && _eraseArmed) {
      final base = _index(addr & 0xf000);
      for (int i = 0; i < 0x1000; i++) {
        storage.write8(base + i, 0xff);
      }
      _eraseArmed = false;
    }
  }
}

/// EEPROM bit-serial protocol driven by DMA. Address width (6 or 14 bits) is
/// inferred from the DMA transfer length each command.
class _Eeprom {
  final Sram storage;
  _Eeprom(this.storage);

  int _addrBits = 6;
  final _rx = <int>[];
  int _expected = 0;

  bool _reading = false;
  int _readAddr = 0;
  int _readCount = 0;

  int get _entries => storage.data.length ~/ 8; // 8 bytes per address

  void beginCommand(int count) {
    if (count == 9 || count == 73) {
      _addrBits = 6;
    } else if (count == 17 || count == 81) {
      _addrBits = 14;
    }
    _rx.clear();
    _expected = count;
  }

  void writeBit(int bit) {
    if (_expected == 0) return;
    _rx.add(bit & 1);
    if (_rx.length < _expected) return;
    _process();
    _expected = 0;
  }

  void _process() {
    final cmd = (_rx[0] << 1) | _rx[1];
    int addr = 0;
    for (int i = 0; i < _addrBits; i++) {
      addr = (addr << 1) | _rx[2 + i];
    }
    addr &= _entries - 1;

    if (cmd == 3) {
      // read request
      _readAddr = addr;
      _readCount = 0;
      _reading = true;
    } else if (cmd == 2) {
      // write: 64 data bits follow the address
      for (int byte = 0; byte < 8; byte++) {
        int v = 0;
        for (int b = 0; b < 8; b++) {
          v = (v << 1) | _rx[2 + _addrBits + byte * 8 + b];
        }
        storage.write8(addr * 8 + byte, v);
      }
    }
  }

  int readBit() {
    if (!_reading) return 1;
    int bit;
    if (_readCount < 4) {
      bit = 0; // 4 leading dummy bits
    } else {
      final idx = _readCount - 4;
      final v = storage.read8(_readAddr * 8 + (idx >> 3));
      bit = (v >> (7 - (idx & 7))) & 1;
    }
    _readCount++;
    if (_readCount >= 68) _reading = false;
    return bit;
  }
}
