import 'dart:typed_data';

import '../../core.dart';
import '../../sram.dart';
import '../../state.dart';
import 'fault.dart';

/// Upper half of a top-boot MBM29F002TC, with A17 tied high on the VA0 board.
/// Operation durations use nominal datasheet values on the 200 MHz timebase.
class DcFlash {
  DcFlash({Set<int> protectedSectors = const {3}})
      : protectedSectors = Set.unmodifiable(protectedSectors) {
    _data.fillRange(0, size, 255);
  }
  static const size = 0x20000;
  static const sectorStarts = [0, 0x10000, 0x18000, 0x1a000, 0x1c000, size];
  static const programClocks = 1600,
      eraseClocks = 200000000,
      selectClocks = 10000;
  final Set<int> protectedSectors;
  final _data = Uint8List(size);
  Sram? _storage;
  int _sequence = 0, _programAddress = 0, _programValue = 0;
  int _programRemaining = 0, _eraseRemaining = 0, _selectionRemaining = 0;
  int _toggle = 0;
  bool _autoselect = false,
      _suspended = false,
      _chipErase = false,
      _failed = false;
  final _eraseSectors = <int>{};

  void validateStateTarget() {
    if (_storage != null && _storage!.data.length != size) {
      throw const StateMismatch('DC flash storage binding layout');
    }
  }

  void saveState(StateWriter writer) {
    writer.section('dc.flash');
    writer.ints(protectedSectors.toList()..sort());
    writer.bytes(exportImage());
    writer.ints([
      _sequence,
      _programAddress,
      _programValue,
      _programRemaining,
      _eraseRemaining,
      _selectionRemaining,
      _toggle
    ]);
    writer.ints(_eraseSectors.toList());
    for (final flag in [_autoselect, _suspended, _chipErase, _failed]) {
      writer.boolean(flag);
    }
  }

  void loadState(StateReader reader) {
    validateStateTarget();
    reader.section('dc.flash');
    final protection = reader.ints(), bytes = reader.bytes();
    final v = reader.ints(), sectors = reader.ints();
    final flags = [for (var i = 0; i < 4; i++) reader.boolean()];
    if (protection.length != protectedSectors.length ||
        protection.toSet().length != protection.length ||
        !protection.every(protectedSectors.contains) ||
        bytes.length != size ||
        v.length != 7 ||
        v.any((value) => value < 0) ||
        v[0] > 6 ||
        v[1] >= size ||
        v[2] > 255 ||
        v[3] > programClocks ||
        v[4] > eraseClocks ||
        v[5] > selectClocks ||
        v[6] & ~0x44 != 0 ||
        sectors.length > 5 ||
        sectors.toSet().length != sectors.length ||
        sectors.any((sector) =>
            sector < 0 || sector > 4 || protectedSectors.contains(sector)) ||
        (flags[1] && v[4] == 0) ||
        (v[5] != 0 && (v[4] == 0 || flags[1]))) {
      throw const StateMismatch('DC flash state or storage configuration');
    }
    _data.setAll(0, bytes);
    // Use the bound storage path for region activation and dirty tracking.
    final storage = _storage;
    if (storage != null) {
      for (var address = 0; address < size; address++) {
        storage.write8(address, bytes[address]);
      }
    }
    _sequence = v[0];
    _programAddress = v[1];
    _programValue = v[2];
    _programRemaining = v[3];
    _eraseRemaining = v[4];
    _selectionRemaining = v[5];
    _toggle = v[6];
    _eraseSectors
      ..clear()
      ..addAll(sectors);
    _autoselect = flags[0];
    _suspended = flags[1];
    _chipErase = flags[2];
    _failed = flags[3];
  }

  bool get arrayMode =>
      !_autoselect &&
      !_failed &&
      _programRemaining == 0 &&
      _eraseRemaining == 0;
  int get clocksToCompletion => _programRemaining != 0
      ? _programRemaining
      : _suspended
          ? 0
          : _selectionRemaining + _eraseRemaining;

  int _sector(int address) {
    for (var i = 0; i < 5; i++) {
      if (address < sectorStarts[i + 1]) return i;
    }
    throw RangeError.range(address, 0, size - 1, 'address');
  }

  int _byte(int address) => _storage?.read8(address) ?? _data[address];
  void _store(int address, int value) {
    _data[address] = value;
    _storage?.write8(address, value);
  }

  void attachStorage(Sram storage) {
    if (_storage != null) {
      for (var i = 0; i < size; i++) {
        _data[i] = _byte(i);
      }
    }
    storage.init(StorageKey.of('dc', StorageKey.sram, 'system_flash'), _data);
    if (storage.data.length != size) {
      throw StateError('DC flash storage must be 128 KiB');
    }
    _storage = storage;
  }

  /// Imports a user-supplied raw image without inventing factory settings.
  void loadImage(Uint8List bytes) {
    if (bytes.length != size) {
      throw ArgumentError('DC flash image must be 128 KiB');
    }
    reset();
    for (var i = 0; i < size; i++) {
      _store(i, bytes[i]);
    }
  }

  Uint8List exportImage() =>
      Uint8List.fromList([for (var i = 0; i < size; i++) _byte(i)]);

  /// Power-cycle reset; the board ties RESET high, so CPU resets do not call this.
  void reset() {
    _sequence =
        _programRemaining = _eraseRemaining = _selectionRemaining = _toggle = 0;
    _autoselect = _suspended = _chipErase = _failed = false;
    _eraseSectors.clear();
  }

  int read(int address, {bool sideEffects = true}) {
    if (address < 0 || address >= size) {
      throw RangeError.range(address, 0, size - 1);
    }
    final sector = _sector(address);
    if (_programRemaining != 0 || _failed) {
      if (sideEffects) _toggle ^= 0x40;
      return ((_programValue ^ 0x80) & 0x80) |
          (_toggle & 0x40) |
          4 |
          (_failed ? 0x20 : 0);
    }
    if (_eraseRemaining != 0) {
      if (_suspended && !_eraseSectors.contains(sector)) return _byte(address);
      if (sideEffects) _toggle ^= _suspended ? 4 : 0x44;
      if (_suspended) return 0xc0 | (_toggle & 4);
      return (_toggle & 0x44) | (_selectionRemaining == 0 ? 8 : 0);
    }
    if (_autoselect) {
      return switch (address & 0x443) {
        0 => 4,
        1 => 0xb0,
        2 => protectedSectors.contains(sector) ? 1 : 0,
        _ => 255, // Undefined autoselect outputs use deterministic ones.
      };
    }
    return _byte(address);
  }

  void write(int address, int value) {
    if (address < 0 || address >= size) {
      throw RangeError.range(address, 0, size - 1);
    }
    value &= 255;
    // The program data cycle accepts every byte, including F0.
    if (_sequence == 3) {
      _sequence = 0;
      final sector = _sector(address);
      if (_suspended && _eraseSectors.contains(sector)) {
        throw DcUnsupported('programming an erase-suspended flash sector');
      }
      if (!protectedSectors.contains(sector)) {
        _programAddress = address;
        _programValue = value;
        _programRemaining = programClocks;
      }
      return;
    }
    if (_programRemaining != 0) return;
    if (_eraseRemaining != 0 && !_suspended) {
      if (value == 0xb0 && !_chipErase) {
        _suspended = true;
        _selectionRemaining = 0;
      } else if (_selectionRemaining != 0 && value == 0x30) {
        _addSector(address);
        _selectionRemaining = selectClocks;
      } else if (_selectionRemaining != 0) {
        // A different command during the selection window cancels the erase.
        reset();
      }
      return;
    }
    if (_suspended && value == 0x30 && _sequence == 0) {
      _suspended = false;
      return;
    }
    if (value == 0xf0) {
      _failed = false;
      _sequence = 0;
      _autoselect = false;
      return;
    }
    if (_autoselect || _failed) return;
    final commandAddress = address & 0x7ff;
    switch (_sequence) {
      case 0:
        _sequence = commandAddress == 0x555 && value == 0xaa ? 1 : 0;
      case 1:
        _sequence = commandAddress == 0x2aa && value == 0x55 ? 2 : 0;
      case 2:
        _sequence = 0;
        if (commandAddress != 0x555) return;
        if (value == 0xa0) {
          _sequence = 3;
        } else if (value == 0x90 && !_suspended) {
          _autoselect = true;
        } else if (value == 0x80 && !_suspended) {
          _sequence = 4;
        }
      case 4:
        _sequence = commandAddress == 0x555 && value == 0xaa ? 5 : 0;
      case 5:
        _sequence = commandAddress == 0x2aa && value == 0x55 ? 6 : 0;
      case 6:
        _sequence = 0;
        if (commandAddress == 0x555 && value == 0x10) {
          _chipErase = true;
          for (var sector = 0; sector < 5; sector++) {
            if (!protectedSectors.contains(sector)) _eraseSectors.add(sector);
          }
          _eraseRemaining = eraseClocks;
        } else if (value == 0x30) {
          _addSector(address);
          _selectionRemaining = selectClocks;
          _eraseRemaining = eraseClocks;
        }
    }
  }

  void _addSector(int address) {
    final sector = _sector(address);
    if (!protectedSectors.contains(sector)) _eraseSectors.add(sector);
  }

  void tickMasterClocks(int clocks) {
    if (clocks < 0) throw ArgumentError.value(clocks, 'clocks');
    if (_programRemaining != 0) {
      if (clocks < _programRemaining) {
        _programRemaining -= clocks;
        return;
      }
      clocks -= _programRemaining;
      _programRemaining = 0;
      _failed = (_byte(_programAddress) & _programValue) != _programValue;
      _store(_programAddress, _byte(_programAddress) & _programValue);
    }
    if (_suspended || _eraseRemaining == 0) return;
    if (_selectionRemaining != 0) {
      if (clocks < _selectionRemaining) {
        _selectionRemaining -= clocks;
        return;
      }
      clocks -= _selectionRemaining;
      _selectionRemaining = 0;
    }
    if (clocks < _eraseRemaining) {
      _eraseRemaining -= clocks;
      return;
    }
    for (final sector in _eraseSectors) {
      for (var address = sectorStarts[sector];
          address < sectorStarts[sector + 1];
          address++) {
        _store(address, 255);
      }
    }
    reset();
  }
}
