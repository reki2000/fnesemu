import '../../state.dart';
import '../../util/int.dart';
import 'fault.dart';

class DcTranslation {
  const DcTranslation(this.physical, this.cacheable, this.writeThrough);
  final int physical;
  final bool cacheable, writeThrough;
}

class _TlbEntry {
  int high = 0, low = 0, assistance = 0;
  bool get valid => low & 0x100 != 0;
  int get offsetMask =>
      [0x3ff, 0xfff, 0xffff, 0xfffff][((low >> 6) & 2) | ((low >> 4) & 1)];
}

/// SH7750 unified/instruction TLBs and software-visible MMU state.
class DcMmu {
  final _unified = List.generate(64, (_) => _TlbEntry());
  final _instruction = List.generate(4, (_) => _TlbEntry());
  int pteh = 0, ptel = 0, ptea = 0, ttb = 0;
  int _control = 0;
  int get control => _control;
  bool get enabled => _control & 1 != 0;

  set control(int value) {
    if (value & 4 != 0) {
      for (final entry in [..._unified, ..._instruction]) {
        entry.low &= ~0x100;
      }
    }
    _control = value & 0xfcfcff01;
  }

  void reset({bool manual = false}) {
    pteh = ptel = ptea = ttb = _control = 0;
    if (!manual) {
      for (final entry in [..._unified, ..._instruction]) {
        entry.low &= ~0x100;
      }
    }
  }

  void saveState(StateWriter writer) {
    writer.section('dc.sh4.mmu');
    writer.ints([pteh, ptel, ptea, ttb, _control]);
    for (final entries in [_unified, _instruction]) {
      writer.ints([
        for (final entry in entries) ...[
          entry.high,
          entry.low,
          entry.assistance
        ]
      ]);
    }
  }

  /// Restore both TLBs directly, retaining stale ITLB entries and LRUI/URC.
  void loadState(StateReader reader) {
    reader.section('dc.sh4.mmu');
    final registers = reader.ints();
    final groups = [_unified, _instruction];
    final values = [reader.ints(), reader.ints()];
    if (registers.length != 5 ||
        registers.any((value) => value < 0 || value > 0xffffffff) ||
        registers[4] & ~0xfcfcff01 != 0) {
      throw const StateMismatch('SH4 MMU control state');
    }
    for (var group = 0; group < 2; group++) {
      final data = values[group];
      if (data.length != groups[group].length * 3) {
        throw const StateMismatch('SH4 TLB layout');
      }
      for (var i = 0; i < data.length; i += 3) {
        if (data[i] < 0 ||
            data[i] & ~0xfffffcff != 0 ||
            data[i + 1] < 0 ||
            data[i + 1] & ~(group == 0 ? 0x1ffffdff : 0x1ffffdda) != 0 ||
            data[i + 2] < 0 ||
            data[i + 2] > 15) {
          throw const StateMismatch('SH4 TLB entry');
        }
      }
    }
    pteh = registers[0];
    ptel = registers[1];
    ptea = registers[2];
    ttb = registers[3];
    _control = registers[4];
    for (var group = 0; group < 2; group++) {
      for (var i = 0; i < groups[group].length; i++) {
        final entry = groups[group][i], data = values[group];
        entry.high = data[i * 3];
        entry.low = data[i * 3 + 1];
        entry.assistance = data[i * 3 + 2];
      }
    }
  }

  void load() {
    final entry = _unified[(_control >> 10) & 63];
    entry.high = pteh & 0xfffffcff;
    entry.low = ptel & 0x1ffffdff;
    entry.assistance = ptea & 15;
  }

  bool _matches(_TlbEntry entry, int address, bool privileged) =>
      entry.valid &&
      ((entry.high ^ address) & (~entry.offsetMask & 0xffffffff)) == 0 &&
      (entry.low & 2 != 0 ||
          (privileged && _control & 0x100 != 0) ||
          (entry.high & 255) == (pteh & 255));

  int _find(List<_TlbEntry> entries, int address, bool privileged,
      {bool instruction = false}) {
    var found = -1;
    for (var i = 0; i < entries.length; i++) {
      if (!_matches(entries[i], address, privileged)) continue;
      if (found >= 0) {
        throw DcCpuException(0x140, address: address, reset: true);
      }
      found = i;
    }
    return found;
  }

  void _advanceCounter() {
    var next = (((_control >> 10) & 63) + 1) & 63;
    final boundary = (_control >> 18) & 63;
    if (boundary != 0 && next == boundary) next = 0;
    _control = (_control & ~0xfc00) | (next << 10);
  }

  int _replacement() {
    final lru = (_control >> 26) & 63;
    if (lru & 0x38 == 0x38) return 0;
    if (lru & 0x26 == 0x06) return 1;
    if (lru & 0x15 == 0x01) return 2;
    if (lru & 0x0b == 0) return 3;
    throw DcUnsupported('prohibited MMUCR.LRUI replacement state');
  }

  void _touchInstruction(int index) {
    const clear = [0x38, 0x26, 0x15, 0x0b];
    const set = [0, 0x20, 0x14, 0x0b];
    final lru = ((_control >> 26) & ~clear[index]) | set[index];
    _control = (_control & 0x03ffffff) | (lru << 26);
  }

  /// Direct regions return null so the bus retains their existing access policy.
  DcTranslation? translate(int address,
      {bool write = false,
      bool instruction = false,
      bool privileged = true,
      bool touch = true,
      bool ram = false}) {
    address = address.mask32;
    final queue = address >= 0xe0000000 && address < 0xe4000000;
    if (queue && !privileged && _control & 0x200 != 0) {
      throw DcCpuException(write ? 0x100 : 0xe0, address: address);
    }
    if (!enabled ||
        ram ||
        (instruction && queue) ||
        (address >= 0x80000000 && address < 0xc0000000) ||
        (address >= 0xe0000000 && !queue)) {
      return null;
    }
    _TlbEntry? entry;
    var instructionIndex = -1;
    if (instruction) {
      instructionIndex =
          _find(_instruction, address, privileged, instruction: true);
      if (instructionIndex >= 0) entry = _instruction[instructionIndex];
    }
    if (entry == null) {
      if (touch) _advanceCounter();
      final index = _find(_unified, address, privileged);
      if (index < 0) {
        throw DcCpuException(write ? 0x60 : 0x40,
            address: address, vector: 0x400);
      }
      entry = _unified[index];
      if (instruction && touch) {
        instructionIndex = _replacement();
        final target = _instruction[instructionIndex];
        target.high = entry.high;
        target.low = entry.low & 0x1ffffdda;
        target.assistance = entry.assistance;
        entry = target;
      }
    }
    if (instruction && touch) _touchInstruction(instructionIndex);
    final protection = (entry.low >> 5) & 3;
    if ((!privileged && protection < 2) ||
        (!instruction && write && protection & 1 == 0)) {
      throw DcCpuException(write ? 0xc0 : 0xa0, address: address);
    }
    if (write && entry.low & 4 == 0) {
      throw DcCpuException(0x80, address: address);
    }
    final physical = (entry.low & (0x1ffffc00 & ~entry.offsetMask)) |
        (address & entry.offsetMask);
    return DcTranslation(physical, entry.low & 8 != 0, entry.low & 1 != 0);
  }

  /// Cache-array associative writes search existing entries without ITLB refill.
  DcTranslation? associative(int address, {bool instruction = false}) {
    if (!instruction) _advanceCounter();
    final entries = instruction ? _instruction : _unified;
    final index = _find(entries, address, true, instruction: instruction);
    if (index < 0) return null;
    final entry = entries[index];
    return DcTranslation(
        (entry.low & (0x1ffffc00 & ~entry.offsetMask)) |
            (address & entry.offsetMask),
        entry.low & 8 != 0,
        entry.low & 1 != 0);
  }

  static bool isArray(int address) =>
      [0xf2, 0xf3, 0xf6, 0xf7].contains(address.mask32 >> 24);

  (_TlbEntry, bool, bool) _arrayEntry(int address) {
    if (address & 3 != 0) throw DcUnsupported('unaligned TLB array access');
    final instruction = address & 0x04000000 == 0;
    return (
      (instruction
          ? _instruction
          : _unified)[(address >> 8) & (instruction ? 3 : 63)],
      address & 0x01000000 != 0,
      instruction
    );
  }

  int readArray(int address) {
    final (entry, data, instruction) = _arrayEntry(address);
    if (data) return address & 0x800000 != 0 ? entry.assistance : entry.low;
    return entry.high |
        (entry.low & 0x100) |
        (instruction ? 0 : (entry.low & 4) << 7);
  }

  void writeArray(int address, int value, {bool privileged = true}) {
    final (entry, data, instruction) = _arrayEntry(address);
    if (data) {
      if (address & 0x800000 != 0) {
        entry.assistance = value & 15;
      } else {
        entry.low = value & (instruction ? 0x1ffffdda : 0x1ffffdff);
      }
    } else if (!instruction && address & 0x80 != 0) {
      final unified = _find(_unified, value & 0xfffffc00, privileged);
      final insn = _find(_instruction, value & 0xfffffc00, privileged,
          instruction: true);
      if (unified >= 0) {
        final target = _unified[unified];
        target.low =
            (target.low & ~0x104) | (value & 0x100) | ((value >> 7) & 4);
      }
      if (insn >= 0) {
        final target = _instruction[insn];
        if (unified >= 0) {
          target.low = _unified[unified].low & 0x1ffffdda;
          target.assistance = _unified[unified].assistance;
        } else {
          target.low = (target.low & ~0x100) | (value & 0x100);
        }
      }
    } else {
      entry.high = value & 0xfffffcff;
      entry.low = (entry.low & ~(instruction ? 0x100 : 0x104)) |
          (value & 0x100) |
          (instruction ? 0 : (value >> 7) & 4);
    }
  }
}
