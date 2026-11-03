import 'dart:typed_data';

import '../../util/int.dart';

/// ARM7 processor modes (CPSR bits 4..0).
class CpuMode {
  static const usr = 0x10;
  static const fiq = 0x11;
  static const irq = 0x12;
  static const svc = 0x13;
  static const abt = 0x17;
  static const und = 0x1b;
  static const sys = 0x1f;
}

/// Banked register file and CPSR/SPSR handling shared by the ARM7 cores.
///
/// The visible [r] holds r0 to r15 of the current mode. r13 and r14 are
/// banked per privileged mode, r8 to r12 are banked for FIQ, and each
/// privileged mode has its own SPSR in [saved]. Banking follows the lazy
/// mirror discipline both cores used: switching banks stores the visible
/// r13/r14 (and r8 to r12 across FIQ) into the old bank and loads the new
/// bank's stored values, leaving the new bank's stored copy stale until
/// the next switch away from it.
///
/// r[15] is the fetch pointer: the address of the executing instruction
/// plus 8 in ARM state, plus 4 in Thumb state. Instruction execution
/// in the shared engine derives the executing address from it.
class Arm7Regs {
  Arm7Regs({
    Uint32List? registers,
    this.strictModes = false,
    this.spsrThrowsInUserBank = false,
    Never Function(String message)? onFault,
  })  : r = registers ?? Uint32List(16),
        onFault = onFault ?? _defaultFault;

  static Never _defaultFault(String message) => throw StateError(message);

  /// Reports an architectural fault the embedding turns into its own
  /// error type (the DC core throws its unsupported-instruction error).
  final Never Function(String message) onFault;

  /// Whether unlisted processor modes fault instead of mapping to the
  /// user bank. The ARM7DI core has no system mode and faults on it,
  /// while the ARM7TDMI core maps system and unlisted modes to bank 0.
  final bool strictModes;

  /// Whether reading or writing the SPSR in the user bank faults. Only
  /// the ARM7DI core faults; the TDMI core reads its unused slot 0.
  final bool spsrThrowsInUserBank;

  /// The visible register file, r0 to r15. r[15] is the fetch pointer.
  final Uint32List r;

  /// The r8 to r12 copies for the non-FIQ banks and for FIQ.
  final userHigh = Uint32List(5), fiqHigh = Uint32List(5);

  /// The banked r13/r14 pairs, indexed by bank (see [bankIndex]).
  final spLr = List.generate(6, (_) => Uint32List(2));

  /// The saved CPSR per bank, indexed by bank (slot 0 is unused).
  final saved = Uint32List(6);

  /// The current CPSR. Written directly only where banking is handled
  /// separately; mode-changing writes go through [setCpsrBanked].
  int cpsr = CpuMode.svc | _iBit | _fBit; // boot in SVC, IRQ/FIQ disabled

  static const _nBit = 0x80000000;
  static const _zBit = 0x40000000;
  static const _cBit = 0x20000000;
  static const _vBit = 0x10000000;
  static const _iBit = 0x00000080; // IRQ disable
  static const _fBit = 0x00000040; // FIQ disable
  static const _tBit = 0x00000020; // THUMB state

  /// The fetch pointer (r[15]); the executing address is 8 (ARM state)
  /// or 4 (Thumb state) below it.
  int get pc => r[15];
  set pc(int v) => r[15] = v.mask32;

  // Condition flags.
  bool get nf => cpsr & _nBit != 0;
  bool get zf => cpsr & _zBit != 0;
  bool get cf => cpsr & _cBit != 0;
  bool get vf => cpsr & _vBit != 0;
  set nf(bool b) => cpsr = cpsr.setBit(31, b).mask32;
  set zf(bool b) => cpsr = cpsr.setBit(30, b).mask32;
  set cf(bool b) => cpsr = cpsr.setBit(29, b).mask32;
  set vf(bool b) => cpsr = cpsr.setBit(28, b).mask32;

  bool get irqDisabled => cpsr & _iBit != 0;
  bool get fiqDisabled => cpsr & _fBit != 0;
  set irqDisabled(bool b) => cpsr = cpsr.setBit(7, b).mask32;
  set fiqDisabled(bool b) => cpsr = cpsr.setBit(6, b).mask32;

  bool get thumb => cpsr & _tBit != 0;
  set thumb(bool b) => cpsr = cpsr.setBit(5, b).mask32;

  int get mode => cpsr.mask5;

  /// Sets N and Z together, leaving C and V untouched.
  void setNZ(bool n, bool z) {
    cpsr = (cpsr & 0x3fffffff) | (n ? _nBit : 0) | (z ? _zBit : 0);
  }

  /// Sets all four condition flags at once.
  void setNZCV(bool n, bool z, bool c, bool v) {
    cpsr = (cpsr & 0x0fffffff) |
        (n ? _nBit : 0) |
        (z ? _zBit : 0) |
        (c ? _cBit : 0) |
        (v ? _vBit : 0);
  }

  /// Maps a processor mode to its bank index: usr/sys 0, fiq 1, irq 2,
  /// svc 3, abt 4, und 5. In strict mode any other mode, including
  /// system mode, faults instead of mapping to bank 0.
  int bankIndex(int mode) => switch (mode & 31) {
        CpuMode.usr => 0,
        CpuMode.fiq => 1,
        CpuMode.irq => 2,
        CpuMode.svc => 3,
        CpuMode.abt => 4,
        CpuMode.und => 5,
        _ => strictModes
            ? onFault(
                'ARM7DI unsupported processor mode: ${mode & 31}')
            : 0,
      };

  /// Swaps the visible banked registers between two banks, storing the
  /// visible values into the old bank and loading the new bank's stored
  /// values. Does nothing when the banks are the same.
  void swapBanks(int oldBank, int newBank) {
    if (oldBank == newBank) return;
    if (oldBank == 1 || newBank == 1) {
      (oldBank == 1 ? fiqHigh : userHigh).setAll(0, r.sublist(8, 13));
      r.setRange(8, 13, newBank == 1 ? fiqHigh : userHigh);
    }
    spLr[oldBank].setAll(0, r.sublist(13, 15));
    r.setRange(13, 15, spLr[newBank]);
  }

  /// Changes the processor mode, banking r8 to r14 appropriately. The
  /// rest of the CPSR is untouched.
  void switchMode(int newMode) {
    final oldMode = mode;
    if (oldMode == newMode) return;
    swapBanks(bankIndex(oldMode), bankIndex(newMode));
    cpsr = cpsr & ~0x1f | newMode.mask5;
  }

  /// Writes the whole CPSR with banking: when [value]'s mode selects a
  /// different bank than the current mode, the banked registers are
  /// swapped first. The stored value is [value] masked by [mask] (the
  /// ARM7DI core clears the Thumb and reserved bits; the TDMI core
  /// stores the value unchanged). An invalid mode in strict mode faults
  /// before any state changes.
  void setCpsrBanked(int value, int mask) {
    final oldBank = bankIndex(mode), newBank = bankIndex(value);
    if (oldBank != newBank) swapBanks(oldBank, newBank);
    cpsr = value & mask;
  }

  int get spsr {
    final bank = bankIndex(mode);
    if (bank == 0 && spsrThrowsInUserBank) {
      onFault('ARM7DI user mode has no SPSR');
    }
    return saved[bank];
  }

  set spsr(int v) {
    final bank = bankIndex(mode);
    if (bank == 0 && spsrThrowsInUserBank) {
      onFault('ARM7DI user mode has no SPSR');
    }
    saved[bank] = v.mask32;
  }

  /// Reads the user/system-bank value of r8 to r14 regardless of the
  /// current mode, for block transfers with the S bit.
  int userModeReg(int n) {
    if (n >= 8 && n <= 12) {
      return mode == CpuMode.fiq ? userHigh[n - 8] : r[n];
    }
    if (n == 13) return bankIndex(mode) == 0 ? r[13] : spLr[0][0];
    if (n == 14) return bankIndex(mode) == 0 ? r[14] : spLr[0][1];
    return r[n];
  }

  /// Writes the user/system-bank value of r8 to r14 regardless of the
  /// current mode, for block transfers with the S bit.
  void setUserModeReg(int n, int v) {
    v &= 0xffffffff;
    if (n >= 8 && n <= 12) {
      if (mode == CpuMode.fiq) {
        userHigh[n - 8] = v;
      } else {
        r[n] = v;
      }
    } else if (n == 13) {
      if (bankIndex(mode) == 0) {
        r[13] = v;
      } else {
        spLr[0][0] = v;
      }
    } else if (n == 14) {
      if (bankIndex(mode) == 0) {
        r[14] = v;
      } else {
        spLr[0][1] = v;
      }
    } else {
      r[n] = v;
    }
  }

  /// Copies the current SPSR back into the CPSR (exception return).
  /// User and system modes have no SPSR, so the CPSR is left as it is.
  void restoreCpsr() {
    if (bankIndex(mode) == 0) return;
    final target = spsr;
    switchMode(target.mask5);
    cpsr = target;
  }

  /// Zeroes the visible registers and boots in SVC with interrupts
  /// disabled. Banked copies are left alone.
  void reset() {
    r.fillRange(0, 16, 0);
    cpsr = CpuMode.svc | _iBit | _fBit;
  }
}
