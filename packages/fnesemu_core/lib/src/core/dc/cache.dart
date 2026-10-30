import 'dart:typed_data';

import '../../state.dart';
import '../../util/int.dart';
import '../../util/uint8list.dart';
import 'fault.dart';

typedef DcExternalMemory = (Uint8List, int) Function(
    int address, int size, bool write);

typedef DcExternalRead = (Uint8List, int) Function(
    int address, int size, bool sideEffects);

typedef DcExternalWrite = void Function(int address, Uint8List values);

/// Direct-mapped SH7750 caches with synchronous fills and write-back.
class DcCache {
  DcCache(this.external,
      {this.readExternal, this.writeExternal, this.readInstructionExternal});

  // Location lookup validates without bus-cycle side effects.
  final DcExternalMemory external;
  final DcExternalRead? readExternal;
  final DcExternalRead? readInstructionExternal;
  final DcExternalWrite? writeExternal;
  final _operand = Uint8List(16384), _instruction = Uint8List(8192);
  final _operandTags = Uint32List(512), _instructionTags = Uint32List(256);
  int _ccr = 0;
  int get ccr => _ccr;

  set ccr(int value) {
    if (value & 8 != 0) {
      for (var i = 0; i < 512; i++) {
        _operandTags[i] &= ~3;
      }
    }
    if (value & 0x800 != 0) {
      for (var i = 0; i < 256; i++) {
        _instructionTags[i] &= ~1;
      }
    }
    _ccr = value & 0x81a7;
  }

  void reset({bool manual = false}) {
    _ccr = 0;
    if (!manual) {
      for (var i = 0; i < 512; i++) {
        _operandTags[i] &= ~3;
      }
      for (var i = 0; i < 256; i++) {
        _instructionTags[i] &= ~1;
      }
    }
  }

  void saveState(StateWriter writer) {
    writer.section('dc.sh4.cache');
    writer.int32(_ccr);
    writer.bytes(_operand);
    writer.bytes(_instruction);
    writer.ints(_operandTags);
    writer.ints(_instructionTags);
  }

  /// Restore stale and dirty lines without invalidation, fill or write-back.
  void loadState(StateReader reader) {
    reader.section('dc.sh4.cache');
    final control = reader.int32();
    final operand = reader.bytes(), instruction = reader.bytes();
    final operandTags = reader.ints(), instructionTags = reader.ints();
    if (control & ~0x81a7 != 0 ||
        operand.length != _operand.length ||
        instruction.length != _instruction.length ||
        operandTags.length != _operandTags.length ||
        instructionTags.length != _instructionTags.length ||
        operandTags.any((tag) => tag < 0 || tag & ~0x1ffffc03 != 0) ||
        instructionTags.any((tag) => tag < 0 || tag & ~0x1ffffc01 != 0)) {
      throw const StateMismatch('SH4 cache state');
    }
    _operand.setAll(0, operand);
    _instruction.setAll(0, instruction);
    _operandTags.setAll(0, operandTags);
    _instructionTags.setAll(0, instructionTags);
    _ccr = control;
  }

  static bool _cacheable(int address) =>
      address < 0xa0000000 && (address & 0x1fffffff) < 0x1c000000;

  static bool isRamArea(int address) =>
      address >= 0x7c000000 && address < 0x80000000;

  int? _ramOffset(int address) {
    if (!isRamArea(address) || _ccr & 0x21 != 0x21) return null;
    final bank = _ccr & 0x80 == 0 ? (address >> 13) & 1 : (address >> 25) & 1;
    return 0x1000 | (bank << 13) | (address & 0xfff);
  }

  int _index(int address, bool instruction) {
    final indexMode = _ccr & (instruction ? 0x8000 : 0x80) != 0;
    var result = indexMode
        ? ((address >> 5) & (instruction ? 127 : 255)) |
            (((address >> 25) & 1) << (instruction ? 7 : 8))
        : (address >> 5) & (instruction ? 255 : 511);
    if (!instruction && _ccr & 0x20 != 0) result &= ~128;
    return result;
  }

  bool _hit(int address, int index, bool instruction) {
    final entry = (instruction ? _instructionTags : _operandTags)[index];
    return entry & 1 != 0 && entry & 0x1ffffc00 == address & 0x1ffffc00;
  }

  void _writeBack(int index) {
    final entry = _operandTags[index];
    if (entry & 3 != 3) return;
    final address = (entry & 0x1ffffc00) | ((index & 31) << 5);
    final (bytes, offset) = external(address, 32, true);
    if (writeExternal != null) {
      writeExternal!(address,
          Uint8List.fromList(_operand.sublist(index * 32, index * 32 + 32)));
    } else {
      bytes.setRange(offset, offset + 32, _operand, index * 32);
    }
    _operandTags[index] &= ~2;
  }

  void _fill(int address, int index, bool instruction,
      {bool allocate = false}) {
    final data = instruction ? _instruction : _operand;
    // Validate the new line before evicting any previous dirty contents.
    final source = allocate ? null : external(address & 0x1fffffe0, 32, false);
    final incomingLocation = source == null
        ? null
        : readExternal?.call(address & 0x1fffffe0, 32, true) ?? source;
    final incoming = incomingLocation == null
        ? null
        : Uint8List.fromList(incomingLocation.$1
            .sublist(incomingLocation.$2, incomingLocation.$2 + 32));
    if (!instruction) _writeBack(index);
    if (incoming != null) {
      data.setRange(index * 32, index * 32 + 32, incoming);
    }
    // MOVCA leaves unwritten bytes undefined; retain their previous values.
    (instruction ? _instructionTags : _operandTags)[index] =
        (address & 0x1ffffc00) | 1;
  }

  /// An untranslated 16-bit instruction fetch that hits the instruction cache,
  /// or -1 when the full path must decide.
  int instructionHit(int address) {
    if (_ccr & 0x100 == 0 || !_cacheable(address) || isRamArea(address)) {
      return -1;
    }
    final index = _index(address, true);
    if (!_hit(address, index, true)) return -1;
    final offset = index * 32 + (address & 31);
    return _instruction[offset] | (_instruction[offset + 1] << 8);
  }

  (Uint8List, int) readLocation(int address, int size,
      {bool instruction = false,
      bool fill = true,
      int? physical,
      bool? cacheable}) {
    address = address.mask32;
    if (address & (size - 1) != 0) {
      throw DcUnsupported('unaligned cache access');
    }
    final ram = _ramOffset(address);
    if (ram != null && !instruction) return (_operand, ram);
    if (instruction && isRamArea(address)) {
      throw DcUnsupported('instruction fetch from operand cache RAM');
    }
    final instructionReader = instruction ? readInstructionExternal : null;
    final Uint8List rawBytes;
    final int rawOffset;
    if (instructionReader != null) {
      (rawBytes, rawOffset) =
          instructionReader(physical ?? address, size, false);
    } else {
      (rawBytes, rawOffset) = external(physical ?? address, size, false);
    }
    if (!(cacheable ?? _cacheable(address)) ||
        _ccr & (instruction ? 0x100 : 1) == 0) {
      if (instructionReader != null) {
        return instructionReader(physical ?? address, size, fill);
      }
      return readExternal?.call(physical ?? address, size, fill) ??
          (rawBytes, rawOffset);
    }
    final index = _index(address, instruction);
    if (!_hit(physical ?? address, index, instruction)) {
      if (!fill) return (rawBytes, rawOffset);
      _fill(physical ?? address, index, instruction);
    }
    return (instruction ? _instruction : _operand, index * 32 + (address & 31));
  }

  void write(int address, Uint8List values,
      {bool allocate = false,
      int? physical,
      bool? cacheable,
      bool? writeThrough}) {
    address = address.mask32;
    final size = values.length;
    if (address & (size - 1) != 0) {
      throw DcUnsupported('unaligned cache write');
    }
    final ram = _ramOffset(address);
    if (ram != null) {
      _operand.setRange(ram, ram + size, values);
      return;
    }
    final (raw, rawOffset) = external(physical ?? address, size, true);
    if (!(cacheable ?? _cacheable(address)) || _ccr & 1 == 0) {
      if (writeExternal != null) {
        writeExternal!(physical ?? address, values);
      } else {
        raw.setRange(rawOffset, rawOffset + size, values);
      }
      return;
    }
    final index = _index(address, false);
    final through =
        writeThrough ?? (address >= 0x80000000 ? _ccr & 4 == 0 : _ccr & 2 != 0);
    final hit = _hit(physical ?? address, index, false);
    if (!hit && !through) {
      _fill(physical ?? address, index, false, allocate: allocate);
    }
    if (through) {
      if (writeExternal != null) {
        writeExternal!(physical ?? address, values);
      } else {
        raw.setRange(rawOffset, rawOffset + size, values);
      }
    }
    if (hit || !through) {
      final offset = index * 32 + (address & 31);
      _operand.setRange(offset, offset + size, values);
      if (!through) _operandTags[index] |= 2;
    }
  }

  void operate(int address, int operation, {int? physical, bool? cacheable}) {
    address = address.mask32;
    if (!(cacheable ?? _cacheable(address)) ||
        _ccr & 1 == 0 ||
        _ramOffset(address) != null) {
      return;
    }
    final index = _index(address, false);
    if (!_hit(physical ?? address, index, false)) return;
    if (operation != 0) _writeBack(index);
    if (operation != 2) _operandTags[index] &= ~1;
  }

  void prefetch(int address, {int? physical, bool? cacheable}) {
    address = address.mask32;
    if (!(cacheable ?? _cacheable(address)) ||
        _ccr & 1 == 0 ||
        isRamArea(address)) {
      return;
    }
    // Address-related failures on ordinary PREF are architecturally suppressed.
    try {
      readLocation(address & ~31, 1,
          physical: physical == null ? null : physical & ~31,
          cacheable: cacheable);
    } on DcUnsupported {
      return;
    }
  }

  static bool isArray(int address) =>
      [0xf0, 0xf1, 0xf4, 0xf5].contains(address.mask32 >> 24);

  int readArray(int address) {
    if (address & 3 != 0) throw DcUnsupported('unaligned cache array access');
    final instruction = (address >> 24) & 4 == 0;
    final mask = instruction ? 0x1fff : 0x3fff;
    final index = (address & mask) >> 5;
    if (address & 0x01000000 == 0) {
      return (instruction ? _instructionTags : _operandTags)[index];
    }
    return (instruction ? _instruction : _operand)
        .getUint32LE(address & mask)
        .mask32;
  }

  void writeArray(int address, int value) {
    if (address & 3 != 0) throw DcUnsupported('unaligned cache array access');
    final instruction = (address >> 24) & 4 == 0;
    final mask = instruction ? 0x1fff : 0x3fff;
    final index = (address & mask) >> 5;
    if (address & 0x01000000 != 0) {
      (instruction ? _instruction : _operand)
          .setUint32LE(address & mask, value);
      return;
    }
    final entries = instruction ? _instructionTags : _operandTags;
    final flags = instruction ? 1 : 3;
    if (address & 8 != 0) {
      if (!_hit(value, index, instruction)) return;
      if (!instruction && value & 3 != 3) _writeBack(index);
      entries[index] = (entries[index] & ~flags) | (value & flags);
    } else {
      if (!instruction) _writeBack(index);
      entries[index] = value & (0x1ffffc00 | flags);
    }
  }
}
