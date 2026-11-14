import 'dart:typed_data';

import 'r5900/r5900.dart';

/// Finds an EE loop that only polls a device register, so that the core
/// can skip its passes instead of running them.
///
/// The loop starts with a load from a register that reads without side
/// effects. The rest of the loop computes in general registers and ends
/// with a branch back to the load and its delay slot. When two passes leave
/// the same registers after the load, each later pass does the same until
/// the register reads another value. The register changes only when the
/// devices run, so [skip] accounts whole passes up to the next device
/// clock and checks the register again after the devices have run.
final class EeIdleLoop {
  EeIdleLoop(this.cpu);

  final R5900 cpu;

  /// the address of the load, or -1 while no loop is watched
  int _pc = -1;
  int _loadWord = 0, _branchAt = 0, _branchWord = 0;

  /// the instructions of one pass
  int _pass = 0;
  int _rt = 0, _size = 0, _device = 0;
  bool _signed = false;

  /// the clocks after the last load, and the registers then
  int _clocks = 0;
  final _regs = Int64List(64);

  /// Addresses that are not the load of such a loop, by their low bits.
  /// The interpreter runs the same few instructions again and again, so
  /// this keeps the check of each instruction to one compare.
  final _rejected = Int32List(256)..fillRange(0, 256, -1);

  /// whether two passes have left the same registers
  bool _idle = false;

  void reset() {
    _pc = -1;
    _rejected.fillRange(0, 256, -1);
    _idle = false;
  }

  /// Called after the interpreter has run the instruction at [at].
  void observe(int at) {
    if (at != _pc) {
      final slot = (at >> 2) & 255;
      if (_rejected[slot] == at.toSigned(32)) return;
      if (!_watch(at)) {
        _rejected[slot] = at;
        return;
      }
      _keep();
      return;
    }
    _idle = cpu.pc == at + 4 &&
        cpu.clocks - _clocks == _pass &&
        _sameRegisters() &&
        _sameCode();
    _keep();
  }

  /// Accounts whole passes of the loop while it reads the same value,
  /// until the first pass that ends at or after [limit]. A pass loads
  /// before [readBefore], from when a register may read a value that
  /// depends on the clock. Returns false when the instructions must run.
  bool skip(int limit, int readBefore) {
    if (!_idle) return false;
    // Without an instruction since the last pass, the registers are those
    // of that pass.
    if (cpu.pc != _pc + 4 ||
        !cpu.prepareCompiled() ||
        cpu.clocks != _clocks && !_sameRegisters() ||
        !_sameCode() ||
        _read() != cpu.reg(_rt)) {
      _idle = false;
      return false;
    }
    final clocks = cpu.clocks;
    var passes = (limit - clocks + _pass - 1) ~/ _pass;
    // the load of pass k runs at clocks + k * _pass - 1
    final early = (readBefore - clocks) ~/ _pass;
    if (early < passes) passes = early;
    final untilCompare = cpu.instructionsUntilCompare;
    if (untilCompare != 0 && passes * _pass >= untilCompare) {
      passes = (untilCompare - 1) ~/ _pass;
    }
    if (passes <= 0) return false;
    cpu.idle(passes * _pass);
    _clocks = cpu.clocks;
    return true;
  }

  void _keep() {
    _clocks = cpu.clocks;
    _regs.setAll(0, cpu.gpr);
  }

  bool _sameRegisters() {
    final gpr = cpu.gpr, regs = _regs;
    for (var i = 0; i < 64; i++) {
      if (gpr[i] != regs[i]) return false;
    }
    return true;
  }

  bool _sameCode() =>
      cpu.bus.read32(_pc) == _loadWord &&
      cpu.bus.read32(_branchAt) == _branchWord;

  /// the value that the load gives now, without side effects
  int _read() {
    final raw = cpu.bus.io!.read(_device, _size);
    final bits = _size * 8;
    final value = raw & ((1 << bits) - 1);
    return _signed ? value.toSigned(bits) : value;
  }

  /// Starts to watch a loop that begins at the load at [at], which the
  /// interpreter has just run.
  bool _watch(int at) {
    _pc = -1;
    _idle = false;
    final bus = cpu.bus;
    if (at & 3 != 0) return false;
    final word = bus.read32(at);
    final op = word >>> 26;
    final (size, signed) = switch (op) {
      32 => (1, true), // LB
      33 => (2, true), // LH
      35 => (4, true), // LW
      36 => (1, false), // LBU
      37 => (2, false), // LHU
      39 => (4, false), // LWU
      _ => (0, false),
    };
    if (size == 0) return false;
    final base = (word >>> 21) & 31, rt = (word >>> 16) & 31;
    if (rt == 0 || base == rt) return false;
    final address = (cpu.reg(base) + (word & 0xffff).toSigned(16)) & 0xffffffff;
    if (address & (size - 1) != 0) return false;
    final device = bus.deviceAddress(address);
    if (device < 0 || !_pure(device)) return false;
    for (var i = 1; i <= 16; i++) {
      final a = at + i * 4;
      // the words of the loop stay on the page of the load
      if ((a + 4) & ~0xfff != at & ~0xfff) return false;
      final w = bus.read32(a);
      final target = _branchTarget(w, a);
      if (target == null) {
        if (!_computes(w)) return false;
        continue;
      }
      if (target != at || !_computes(bus.read32(a + 4))) return false;
      _pc = at;
      _loadWord = word;
      _branchAt = a;
      _branchWord = w;
      _pass = i + 2;
      _rt = rt;
      _size = size;
      _signed = signed;
      _device = device;
      return true;
    }
    return false;
  }

  /// Registers whose reads have no side effects and change only when the
  /// devices run, or by the clock as [skip] allows for.
  static bool _pure(int device) =>
      device == 0x1000f000 || // INTC_STAT
      device == 0x1000f010 || // INTC_MASK
      (device >= 0x1000e000 && device <= 0x1000e050 && device & 0xf == 0) ||
      device == 0x1000f520 || // D_ENABLER
      (device >= 0x1000f200 && device <= 0x1000f260 && device & 0xf == 0) ||
      device == 0x12001000; // GS CSR

  /// the target of a conditional branch, or null for another instruction
  static int? _branchTarget(int word, int at) {
    final op = word >>> 26;
    final isBranch = switch (op) {
      1 => ((word >>> 16) & 31) <= 3, // BLTZ, BGEZ and their likely forms
      4 || 5 || 6 || 7 => true, // BEQ, BNE, BLEZ, BGTZ
      20 || 21 || 22 || 23 => true, // the likely forms
      _ => false,
    };
    if (!isBranch) return null;
    return (at + 4 + ((word & 0xffff).toSigned(16) << 2)) & 0xffffffff;
  }

  /// Whether [word] only computes in general registers, without traps.
  static bool _computes(int word) {
    final op = word >>> 26;
    if (op == 0) {
      return switch (word & 0x3f) {
        // SLL, SRL, SRA, ADDU, SUBU, AND, OR, XOR, NOR, SLT, SLTU
        0 || 2 || 3 || 0x21 || 0x23 || 0x24 || 0x25 || 0x26 || 0x27 => true,
        0x2a || 0x2b => true,
        _ => false,
      };
    }
    // ADDIU, SLTI, SLTIU, ANDI, ORI, XORI, LUI
    return op >= 9 && op <= 15;
  }
}
