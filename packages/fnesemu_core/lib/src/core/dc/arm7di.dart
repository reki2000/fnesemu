import 'dart:typed_data';

import '../../state.dart';
import '../../util/int.dart';
import 'fault.dart';

/// ARM7DI 32-bit interpreter, based on ARM7DI Data Sheet DDI 0027D.
/// Kept independent of the GBA ARMv4T core: no Thumb or ARMv4 extensions.
/// Cycle totals assume one clock for each S/N/I cycle and no external waits.
class DcArm7di {
  /// [memory] is accessed directly; other addresses go through [read]
  /// and [write].
  DcArm7di({required this.read, required this.write, Uint8List? memory})
      : _memory = memory ?? Uint8List(0),
        _words = ByteData.sublistView(memory ?? Uint8List(0)) {
    reset();
  }
  final int Function(int address, int size) read;
  final void Function(int address, int size, int value) write;
  final Uint8List _memory;
  final ByteData _words;

  int _read(int address, int size) {
    if (address >= 0 && address + size <= _memory.length) {
      return size == 1
          ? _memory[address]
          : _words.getUint32(address, Endian.little);
    }
    return read(address, size);
  }

  void _write(int address, int size, int value) {
    if (address >= 0 && address + size <= _memory.length) {
      if (size == 1) {
        _memory[address] = value;
      } else {
        _words.setUint32(address, value & 0xffffffff, Endian.little);
      }
      return;
    }
    write(address, size, value);
  }

  final r = Uint32List(16);
  final _userHigh = Uint32List(5), _fiqHigh = Uint32List(5);
  final _spLr = List.generate(6, (_) => Uint32List(2));
  final _saved = Uint32List(6);
  int _cpsr = 0xd3, _nextPc = 0;
  int cycles = 0;
  bool instructionExecuted = false;
  bool irq = false, fiq = false;
  int get pc => r[15];
  set pc(int value) => r[15] = value & 0xfffffffc;
  int get cpsr => _cpsr;
  int get mode => _cpsr & 31;

  int _bank(int value) => switch (value & 31) {
        0x10 => 0,
        0x11 => 1,
        0x12 => 2,
        0x13 => 3,
        0x17 => 4,
        0x1b => 5,
        _ => throw DcUnsupported(
            'ARM7DI unsupported processor mode: ${value & 31}'),
      };

  set cpsr(int value) {
    final oldBank = _bank(_cpsr), newBank = _bank(value);
    if (oldBank != newBank) {
      _spLr[oldBank].setAll(0, r.sublist(13, 15));
      r.setRange(13, 15, _spLr[newBank]);
      if (oldBank == 1 || newBank == 1) {
        (oldBank == 1 ? _fiqHigh : _userHigh).setAll(0, r.sublist(8, 13));
        r.setRange(8, 13, newBank == 1 ? _fiqHigh : _userHigh);
      }
    }
    _cpsr = value & 0xf00000df;
  }

  int get spsr {
    final bank = _bank(mode);
    if (bank == 0) throw const DcUnsupported('ARM7DI user mode has no SPSR');
    return _saved[bank];
  }

  set spsr(int value) {
    final bank = _bank(mode);
    if (bank == 0) throw const DcUnsupported('ARM7DI user mode has no SPSR');
    _saved[bank] = value;
  }

  void reset() {
    r.fillRange(0, 16, 0);
    _userHigh.fillRange(0, 5, 0);
    _fiqHigh.fillRange(0, 5, 0);
    for (final bank in _spLr) {
      bank.fillRange(0, 2, 0);
    }
    _saved.fillRange(0, 6, 0);
    _cpsr = 0xd3;
    cycles = 0;
    instructionExecuted = false;
    irq = fiq = false;
  }

  List<List<int>> get _stateBanks => [r, _userHigh, _fiqHigh, ..._spLr, _saved];

  /// Instruction-boundary state; memory and bus callbacks belong to AICA.
  void saveState(StateWriter writer) {
    writer.section('dc.arm7di');
    for (final bank in _stateBanks) {
      writer.ints(bank);
    }
    writer.int32(_cpsr);
    writer.int64(cycles);
    writer.boolean(instructionExecuted);
    writer.boolean(irq);
    writer.boolean(fiq);
  }

  void loadState(StateReader reader) {
    reader.section('dc.arm7di');
    final banks = _stateBanks;
    final values = [for (final _ in banks) reader.ints()];
    final status = reader.int32() & 0xffffffff;
    final elapsed = reader.int64();
    final executed = reader.boolean(),
        irqLevel = reader.boolean(),
        fiqLevel = reader.boolean();
    for (var i = 0; i < banks.length; i++) {
      if (values[i].length != banks[i].length ||
          values[i].any((value) => value < 0 || value > 0xffffffff)) {
        throw const StateMismatch('ARM7DI register bank');
      }
    }
    if (status & ~0xf00000df != 0 ||
        !const [0x10, 0x11, 0x12, 0x13, 0x17, 0x1b].contains(status & 31) ||
        values[0][15] & 3 != 0 ||
        elapsed < 0) {
      throw const StateMismatch('ARM7DI control state');
    }
    for (var i = 0; i < banks.length; i++) {
      banks[i].setAll(0, values[i]);
    }
    // Assign directly: the banking setter would overwrite restored banks.
    _cpsr = status;
    _nextPc = pc;
    cycles = elapsed;
    instructionExecuted = executed;
    irq = irqLevel;
    fiq = fiqLevel;
  }

  // Bit f of entry c is set when condition c passes with NZCV flags f.
  static final _conditions = Uint16List.fromList([
    for (var condition = 0; condition < 16; condition++)
      [
        for (var flags = 0; flags < 16; flags++)
          _passes(condition, flags) ? 1 << flags : 0
      ].fold(0, (mask, bit) => mask | bit)
  ]);

  static bool _passes(int condition, int flags) {
    final n = flags & 8 != 0, z = flags & 4 != 0;
    final c = flags & 2 != 0, v = flags & 1 != 0;
    return switch (condition) {
      0 => z,
      1 => !z,
      2 => c,
      3 => !c,
      4 => n,
      5 => !n,
      6 => v,
      7 => !v,
      8 => c && !z,
      9 => !c || z,
      10 => n == v,
      11 => n != v,
      12 => !z && n == v,
      13 => z || n != v,
      14 => true,
      _ => false,
    };
  }

  bool _condition(int value) => (_conditions[value] >> (_cpsr >>> 28)) & 1 != 0;

  int _reg(int index, {int ahead = 8}) =>
      index == 15 ? (pc + ahead).mask32 : r[index];
  int _ror(int value, int amount) => amount == 0
      ? value.mask32
      : ((value >>> amount) | (value << (32 - amount))).mask32;

  (int, bool) _shift(int value, int type, int amount,
      {required bool immediate}) {
    final carry = _cpsr & 0x20000000 != 0;
    if (amount == 0) {
      if (!immediate || type == 0) return (value, carry);
      if (type == 3) {
        return ((value >>> 1) | (carry ? 0x80000000 : 0), value & 1 != 0);
      }
      amount = 32;
    }
    switch (type) {
      case 0:
        return (
          amount >= 32 ? 0 : (value << amount).mask32,
          amount > 32 ? false : value & (1 << (32 - amount)) != 0
        );
      case 1:
        return (
          amount >= 32 ? 0 : value >>> amount,
          amount > 32 ? false : value & (1 << (amount - 1)) != 0
        );
      case 2:
        final count = amount > 32 ? 32 : amount;
        return (
          (value.rel32 >> (count == 32 ? 31 : count)).mask32,
          value & (1 << (count - 1)) != 0
        );
      default:
        final result = _ror(value, amount & 31);
        return (result, result & 0x80000000 != 0);
    }
  }

  (int, bool) _operand(int op) {
    if (op & 0x02000000 != 0) {
      final rotate = ((op >> 8) & 15) * 2;
      final value = _ror(op & 255, rotate);
      return (
        value,
        rotate == 0 ? _cpsr & 0x20000000 != 0 : value & 0x80000000 != 0
      );
    }
    final byRegister = op & 16 != 0;
    if (byRegister && op & 128 != 0) {
      throw const DcUnsupported('ARM7DI undefined register-shift encoding');
    }
    return _shift(_reg(op & 15, ahead: byRegister ? 12 : 8), (op >> 5) & 3,
        byRegister ? _reg((op >> 8) & 15) & 255 : (op >> 7) & 31,
        immediate: !byRegister);
  }

  (int, bool, bool) _add(int a, int b, int carry) {
    final sum = a + b + carry, result = (a + b + carry).mask32;
    return (
      result,
      sum > 0xffffffff,
      a.rel32 + b.rel32 + carry != result.rel32
    );
  }

  void _flags(int value, bool carry, {bool? overflow}) {
    _cpsr = (_cpsr & (overflow == null ? 0x1fffffff : 0x0fffffff)) |
        (value & 0x80000000) |
        (value == 0 ? 0x40000000 : 0) |
        (carry ? 0x20000000 : 0) |
        (overflow == true ? 0x10000000 : 0);
  }

  int _exception(int vector, int targetMode, int link, {bool fast = false}) {
    final old = _cpsr;
    cpsr = (_cpsr & ~31) | targetMode | 0x80 | (fast ? 0x40 : 0);
    spsr = old;
    r[14] = link;
    pc = vector;
    cycles += 3;
    return 3;
  }

  /// Executes one instruction, or accepts one interrupt before fetching.
  int step() {
    instructionExecuted = false;
    if (fiq && _cpsr & 0x40 == 0) {
      return _exception(0x1c, 0x11, pc + 4, fast: true);
    }
    if (irq && _cpsr & 0x80 == 0) return _exception(0x18, 0x12, pc + 4);
    final op = _read(pc, 4).mask32;
    _nextPc = (pc + 4).mask32;
    var cost = 1;
    if (_condition(op >>> 28)) {
      if (op & 0x0f000000 == 0x0f000000) {
        return _trap(8, 0x13);
      } else if (op & 0x0e000000 == 0x0a000000) {
        if (op & 0x01000000 != 0) r[14] = pc + 4;
        final offset = ((op & 0xffffff) ^ 0x800000) - 0x800000;
        _nextPc = (pc + 8 + offset * 4).mask32;
        cost = 3;
      } else if (op & 0x0fbf0fff == 0x010f0000) {
        final rd = (op >> 12) & 15;
        if (rd == 15) throw const DcUnsupported('ARM7DI MRS PC');
        r[rd] = op & 0x400000 != 0 ? spsr : _cpsr;
      } else if (op & 0x0fbffff0 == 0x0129f000 ||
          op & 0x0fbffff0 == 0x0128f000 ||
          op & 0x0fbff000 == 0x0328f000) {
        _msr(op);
      } else if (op & 0x0fc000f0 == 0x00000090) {
        cost = _multiply(op);
      } else if (op & 0x0fb00ff0 == 0x01000090) {
        final rn = (op >> 16) & 15, rd = (op >> 12) & 15, rm = op & 15;
        if (rn == 15 || rd == 15 || rm == 15) {
          throw const DcUnsupported('ARM7DI SWP PC');
        }
        final address = r[rn], source = r[rm], byte = op & 0x400000 != 0;
        final value = _load(address, byte);
        _write(byte ? address : address & 0xfffffffc, byte ? 1 : 4, source);
        r[rd] = value;
        cost = 4;
      } else if (op & 0x0e000000 == 0x08000000) {
        cost = _block(op);
      } else if (op & 0x0c000000 == 0x04000000) {
        if (op & 0x02000010 == 0x02000010) return _trap(4, 0x1b);
        cost = _transfer(op);
      } else if (op & 0x0c000000 == 0) {
        if (op & 0x02000090 == 0x90) {
          throw DcUnsupported('ARM7DI reserved instruction: ${op.x8}');
        }
        cost = _data(op);
      } else {
        // AICA has no external coprocessor to accept this instruction.
        return _trap(4, 0x1b);
      }
    }
    pc = _nextPc;
    cycles += cost;
    instructionExecuted = true;
    return cost;
  }

  int _trap(int vector, int targetMode) {
    final cost = _exception(vector, targetMode, pc + 4);
    instructionExecuted = true;
    return cost;
  }

  /// Logical state for debugger loop detection, excluding elapsed clocks.
  List<int> get debugState => [
        ...r,
        _cpsr,
        ..._userHigh,
        ..._fiqHigh,
        for (final bank in _spLr) ...bank,
        ..._saved,
        irq ? 1 : 0,
        fiq ? 1 : 0,
      ];

  void _msr(int op) {
    final immediate = op & 0x02000000 != 0;
    if (!immediate && op & 15 == 15) throw const DcUnsupported('ARM7DI MSR PC');
    final value = immediate ? _ror(op & 255, ((op >> 8) & 15) * 2) : r[op & 15];
    final saved = op & 0x400000 != 0;
    final whole = op & 0x10000 != 0;
    final mask = whole && (saved || mode != 0x10) ? 0xf00000df : 0xf0000000;
    if (saved) {
      spsr = (spsr & ~mask) | (value & mask);
    } else {
      cpsr = (_cpsr & ~mask) | (value & mask);
    }
  }

  int _data(int op) {
    final code = (op >> 21) & 15, rd = (op >> 12) & 15;
    final set = op & 0x100000 != 0, test = code >= 8 && code <= 11;
    if (test && !set) throw const DcUnsupported('ARM7DI reserved PSR encoding');
    final registerShift = op & 0x02000010 == 16;
    if (test && rd == 15) {
      if (code != 9) {
        throw const DcUnsupported('ARM7DI deprecated status-test encoding');
      }
      // DDI 0027D specifies this legacy TEQP effect in 32-bit modes.
      if (mode != 0x10) cpsr = spsr;
      return registerShift ? 2 : 1;
    }
    final a = _reg((op >> 16) & 15, ahead: registerShift ? 12 : 8);
    final (b, carry) = _operand(op);
    var result = 0, c = carry;
    bool? overflow;
    // Codes 2-7, 10 and 11: SUB, RSB, ADD, ADC, SBC, RSC, CMP and CMN.
    if ((0xcfc >> code) & 1 != 0) {
      final cin = _cpsr & 0x20000000 != 0 ? 1 : 0;
      final arithmetic = switch (code) {
        2 || 10 => _add(a, (~b).mask32, 1),
        3 => _add(b, (~a).mask32, 1),
        4 || 11 => _add(a, b, 0),
        5 => _add(a, b, cin),
        6 => _add(a, (~b).mask32, cin),
        _ => _add(b, (~a).mask32, cin),
      };
      (result, c, overflow) = arithmetic;
    } else {
      result = switch (code) {
        0 || 8 => a & b,
        1 || 9 => a ^ b,
        12 => a | b,
        13 => b,
        14 => a & ~b,
        _ => ~b,
      };
      result = result.mask32;
    }
    if (!test && rd == 15) {
      if (set) cpsr = spsr;
      _nextPc = result & 0xfffffffc;
    } else {
      if (set) _flags(result, c, overflow: overflow);
      if (!test) r[rd] = result;
    }
    return (registerShift ? 2 : 1) + (!test && rd == 15 ? 2 : 0);
  }

  int _multiply(int op) {
    final rd = (op >> 16) & 15, rn = (op >> 12) & 15;
    final rs = (op >> 8) & 15, rm = op & 15, accumulate = op & 0x200000 != 0;
    if (rd == 15 ||
        rn == 15 ||
        rs == 15 ||
        rm == 15 ||
        (accumulate && rd == rm)) {
      throw const DcUnsupported(
          'ARM7DI prohibited multiply register combination');
    }
    final a = r[rm], b = r[rs];
    final product = rd == rm
        ? 0
        : ((a & 0xffff) * (b & 0xffff) +
                (((a >>> 16) * (b & 0xffff) + (b >>> 16) * (a & 0xffff)) &
                        0xffff) *
                    65536)
            .mask32;
    final result = (product + (accumulate ? r[rn] : 0)).mask32;
    if (op & 0x100000 != 0) _flags(result, _cpsr & 0x20000000 != 0);
    r[rd] = result;
    var iterations = 1;
    while (iterations < 16 && b >= (1 << (2 * iterations - 1))) {
      iterations++;
    }
    return 1 + iterations;
  }

  int _load(int address, bool byte) {
    if (byte) return _read(address, 1) & 255;
    return _ror(_read(address & 0xfffffffc, 4).mask32, (address & 3) * 8);
  }

  int _transfer(int op) {
    final rn = (op >> 16) & 15, rd = (op >> 12) & 15;
    final pre = op & 0x1000000 != 0, up = op & 0x800000 != 0;
    final load = op & 0x100000 != 0, byte = op & 0x400000 != 0;
    final back = !pre || op & 0x200000 != 0;
    if (rn == 15 && back) throw const DcUnsupported('ARM7DI writeback to PC');
    if (byte && rd == 15) {
      throw const DcUnsupported('ARM7DI byte transfer with PC');
    }
    final base = _reg(rn);
    var offset = op & 0xfff;
    if (op & 0x2000000 != 0) {
      if (op & 15 == 15 || (!pre && op & 15 == rn)) {
        throw const DcUnsupported('ARM7DI prohibited transfer offset register');
      }
      offset =
          _shift(r[op & 15], (op >> 5) & 3, (op >> 7) & 31, immediate: true).$1;
    }
    if (load && back && rn == rd) {
      throw const DcUnsupported('ARM7DI load/writeback register overlap');
    }
    final modified = (base + (up ? offset : -offset)).mask32;
    final address = pre ? modified : base;
    if (load) {
      final value = _load(address, byte);
      if (back) r[rn] = modified;
      if (rd == 15) {
        _nextPc = value & 0xfffffffc;
      } else {
        r[rd] = value;
      }
    } else {
      _write(byte ? address : address & 0xfffffffc, byte ? 1 : 4,
          _reg(rd, ahead: 12));
      if (back) r[rn] = modified;
    }
    return load ? (rd == 15 ? 5 : 3) : 2;
  }

  int _user(int index) {
    if (index >= 13 && index <= 14 && mode != 0x10) return _spLr[0][index - 13];
    if (index >= 8 && index <= 12 && mode == 0x11) return _userHigh[index - 8];
    return _reg(index, ahead: 12);
  }

  void _setUser(int index, int value) {
    if (index >= 13 && index <= 14 && mode != 0x10) {
      _spLr[0][index - 13] = value;
    } else if (index >= 8 && index <= 12 && mode == 0x11) {
      _userHigh[index - 8] = value;
    } else {
      r[index] = value;
    }
  }

  int _block(int op) {
    final rn = (op >> 16) & 15, load = op & 0x100000 != 0;
    final up = op & 0x800000 != 0, pre = op & 0x1000000 != 0;
    final special = op & 0x400000 != 0, back = op & 0x200000 != 0;
    final list = [
      for (var i = 0; i < 16; i++)
        if (op & (1 << i) != 0) i
    ];
    if (list.isEmpty || rn == 15 || (special && mode == 0x10)) {
      throw const DcUnsupported('ARM7DI prohibited block transfer');
    }
    final restore = special && load && list.last == 15;
    final user = special && !restore;
    if (user && back) {
      throw const DcUnsupported('ARM7DI user-bank block writeback');
    }
    final saved = restore ? spsr : 0;
    if (restore) _bank(saved);
    final base = r[rn], bytes = list.length * 4;
    final modified = (base + (up ? bytes : -bytes)).mask32;
    var address =
        (up ? base + (pre ? 4 : 0) : base - bytes + (pre ? 0 : 4)).mask32;
    for (final index in list) {
      if (load) {
        final value = _read(address & 0xfffffffc, 4).mask32;
        if (index == 15) {
          _nextPc = value & 0xfffffffc;
        } else if (user) {
          _setUser(index, value);
        } else {
          r[index] = value;
        }
      } else {
        final value = user
            ? _user(index)
            : back && index == rn && index != list.first
                ? modified
                : _reg(index, ahead: 12);
        _write(address & 0xfffffffc, 4, value);
      }
      address = (address + 4).mask32;
    }
    if (back && !(load && list.contains(rn))) r[rn] = modified;
    if (restore) cpsr = saved;
    return list.length + (load ? (list.last == 15 ? 4 : 2) : 1);
  }
}
