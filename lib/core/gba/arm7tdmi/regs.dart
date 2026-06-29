import 'package:fnesemu/util/int.dart';

/// ARM7TDMI processor modes (CPSR bits 4..0)
class CpuMode {
  static const usr = 0x10;
  static const fiq = 0x11;
  static const irq = 0x12;
  static const svc = 0x13;
  static const abt = 0x17;
  static const und = 0x1b;
  static const sys = 0x1f;
}

/// banked register file + CPSR/SPSR handling.
///
/// r[0..15] are the *currently visible* registers. r[15] is PC.
/// On mode switch, banked registers are saved/restored via [_switchBank].
class Regs {
  // visible registers r0-r15
  final r = List<int>.filled(16, 0);

  // banked copies. low banks (r8-r12) only differ for FIQ.
  // sp(r13)/lr(r14) are banked per privileged mode; usr/sys share.
  final _fiqR8to12 = List<int>.filled(5, 0); // fiq r8-r12
  final _usrR8to12 = List<int>.filled(5, 0); // non-fiq r8-r12

  // r13(sp), r14(lr) banks indexed by a small mode id
  final _sp = List<int>.filled(6, 0); // [usr/sys, fiq, irq, svc, abt, und]
  final _lr = List<int>.filled(6, 0);

  // saved program status registers per privileged mode (index as above, 0 unused)
  final _spsr = List<int>.filled(6, 0);

  int cpsr = CpuMode.svc | _iBit | _fBit; // boot in SVC, IRQ/FIQ disabled

  static const _nBit = 0x80000000;
  static const _zBit = 0x40000000;
  static const _cBit = 0x20000000;
  static const _vBit = 0x10000000;
  static const _iBit = 0x00000080; // IRQ disable
  static const _fBit = 0x00000040; // FIQ disable
  static const _tBit = 0x00000020; // THUMB state

  int get pc => r[15];
  set pc(int v) => r[15] = v.mask32;

  // condition flags
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

  bool get thumb => cpsr & _tBit != 0;
  set thumb(bool b) => cpsr = cpsr.setBit(5, b).mask32;

  int get mode => cpsr & 0x1f;

  /// set N/Z together, leaving C/V untouched.
  void setNZ(bool n, bool z) {
    cpsr = (cpsr & 0x3fffffff) | (n ? _nBit : 0) | (z ? _zBit : 0);
  }

  /// set all four condition flags at once.
  void setNZCV(bool n, bool z, bool c, bool v) {
    cpsr = (cpsr & 0x0fffffff) |
        (n ? _nBit : 0) |
        (z ? _zBit : 0) |
        (c ? _cBit : 0) |
        (v ? _vBit : 0);
  }

  // map a mode to the sp/lr/spsr bank index
  static int _bankOf(int mode) => switch (mode) {
        CpuMode.fiq => 1,
        CpuMode.irq => 2,
        CpuMode.svc => 3,
        CpuMode.abt => 4,
        CpuMode.und => 5,
        _ => 0, // usr / sys
      };

  /// change processor mode, banking r8-r14 and spsr appropriately.
  void switchMode(int newMode) {
    final oldMode = mode;
    if (oldMode == newMode) return;
    _switchBank(oldMode, newMode);
    cpsr = (cpsr & ~0x1f) | (newMode & 0x1f);
  }

  void _switchBank(int oldMode, int newMode) {
    final oldFiq = oldMode == CpuMode.fiq;
    final newFiq = newMode == CpuMode.fiq;

    if (oldFiq != newFiq) {
      final saveTo = oldFiq ? _fiqR8to12 : _usrR8to12;
      final loadFrom = newFiq ? _fiqR8to12 : _usrR8to12;
      for (int i = 0; i < 5; i++) {
        saveTo[i] = r[8 + i];
        r[8 + i] = loadFrom[i];
      }
    }

    final ob = _bankOf(oldMode);
    final nb = _bankOf(newMode);
    if (ob != nb) {
      _sp[ob] = r[13];
      _lr[ob] = r[14];
      r[13] = _sp[nb];
      r[14] = _lr[nb];
    }
  }

  int get spsr => _spsr[_bankOf(mode)];
  set spsr(int v) => _spsr[_bankOf(mode)] = v.mask32;

  /// read the user/system-bank value of r8-r14 regardless of current mode.
  int userModeReg(int n) {
    if (n >= 8 && n <= 12) {
      return mode == CpuMode.fiq ? _usrR8to12[n - 8] : r[n];
    }
    if (n == 13) return _bankOf(mode) == 0 ? r[13] : _sp[0];
    if (n == 14) return _bankOf(mode) == 0 ? r[14] : _lr[0];
    return r[n];
  }

  /// write the user/system-bank value of r8-r14 regardless of current mode.
  void setUserModeReg(int n, int v) {
    v &= 0xffffffff;
    if (n >= 8 && n <= 12) {
      if (mode == CpuMode.fiq) {
        _usrR8to12[n - 8] = v;
      } else {
        r[n] = v;
      }
    } else if (n == 13) {
      if (_bankOf(mode) == 0) {
        r[13] = v;
      } else {
        _sp[0] = v;
      }
    } else if (n == 14) {
      if (_bankOf(mode) == 0) {
        r[14] = v;
      } else {
        _lr[0] = v;
      }
    } else {
      r[n] = v;
    }
  }

  /// copy current SPSR back into CPSR (used on exception return).
  void restoreCpsr() {
    final target = spsr;
    switchMode(target & 0x1f);
    cpsr = target;
  }

  void reset() {
    for (int i = 0; i < 16; i++) {
      r[i] = 0;
    }
    cpsr = CpuMode.svc | _iBit | _fBit;
  }
}
