import 'package:fnesemu/util/int.dart';
// Dart imports:
import 'dart:developer';

// Project imports:
import 'bus.dart';

class Regs {
  int a = 0; // 16-bit accumulator (C); low 8 = A, high 8 = B
  int x = 0; // 16-bit index
  int y = 0; // 16-bit index
  int s = 0x01ff; // 16-bit stack pointer
  int d = 0; // 16-bit direct page register
  int pc = 0; // 16-bit program counter
  int pbr = 0; // program bank (b16..b23 of code address)
  int dbr = 0; // data bank
  int p = 0x34; // status (M,X,I set on reset)
  bool e = true; // emulation mode
}

class Flags {
  static const C = 0x01;
  static const Z = 0x02;
  static const I = 0x04;
  static const D = 0x08;
  static const X = 0x10; // index width (1=8bit). also B in emulation
  static const M = 0x20; // accumulator width (1=8bit)
  static const V = 0x40;
  static const N = 0x80;
}

class Cpu {
  final regs = Regs();
  final Bus bus;

  Cpu(this.bus) {
    bus.cpu = this;
  }

  int cycle = 0;
  bool stopped = false; // STP
  bool waiting = false; // WAI

  /// debug read (no side effects beyond bus reads)
  int peek(int addr) => bus.read(addr.mask24);

  // ---------------------------------------------------------------- widths
  @pragma('vm:prefer-inline')
  int get mSize => (regs.e || regs.p.bit5) ? 1 : 2; // accumulator bytes
  @pragma('vm:prefer-inline')
  int get xSize => (regs.e || regs.p.bit4) ? 1 : 2; // index bytes

  // -------------------------------------------------------- memory helpers
  @pragma('vm:prefer-inline')
  int _read8(int addr) => bus.read(addr.mask24);
  @pragma('vm:prefer-inline')
  void _write8(int addr, int v) => bus.write(addr.mask24, v.mask8);

  int _read(int addr, int size) => size == 1
      ? _read8(addr)
      : _read8(addr) | _read8((addr + 1).mask24).shl8;

  void _write(int addr, int v, int size) {
    _write8(addr, v.mask8);
    if (size == 2) _write8((addr + 1).mask24, v.shr8);
  }

  // pointer reads with bank-0 16-bit wrap
  int _ptr16(int p) => _read8(p) | _read8(p.inc.mask16).shl8;
  int _ptr24(int p) =>
      _read8(p) | _read8(p.inc.mask16).shl8 | _read8(p.inc2.mask16).shl16;

  // pointer read within the current program bank (used by indexed indirect
  // JMP/JSR, which - unlike the non-indexed forms - do not force bank 0)
  int _ptr16Pbr(int p) {
    final base = regs.pbr.shl16;
    return _read8(base | p) | _read8(base | p.inc.mask16).shl8;
  }

  // ------------------------------------------------------------ fetch (pc)
  @pragma('vm:prefer-inline')
  int _fetch8() {
    final v = _read8(regs.pbr.shl16 | regs.pc);
    regs.pc = regs.pc.inc.mask16;
    return v;
  }

  int _fetch16() => _fetch8() | _fetch8().shl8;
  int _fetch24() => _fetch8() | _fetch8().shl8 | _fetch8().shl16;

  // ------------------------------------------------------------ stack ops
  void _push8(int v) {
    _write8(regs.s, v);
    regs.s = regs.e ? 0x0100 | regs.s.dec.mask8 : regs.s.dec.mask16;
  }

  int _pull8() {
    regs.s = regs.e ? 0x0100 | regs.s.inc.mask8 : regs.s.inc.mask16;
    return _read8(regs.s);
  }

  void _push16(int v) {
    _push8(v.shr8);
    _push8(v.mask8);
  }

  int _pull16() => _pull8() | _pull8().shl8;

  // ----------------------------------------------------- register access
  @pragma('vm:prefer-inline')
  int get _a => mSize == 1 ? regs.a.mask8 : regs.a.mask16;
  void _setA(int v) =>
      regs.a = mSize == 1 ? regs.a.setL8(v) : v.mask16;
  void _setX(int v) => regs.x = xSize == 1 ? v.mask8 : v.mask16;
  void _setY(int v) => regs.y = xSize == 1 ? v.mask8 : v.mask16;

  // ---------------------------------------------------- addressing modes
  // each returns the 24-bit effective address
  int _dp() => (regs.d + _fetch8()).mask16;
  int _dpX() => (regs.d + _fetch8() + regs.x).mask16;
  int _dpY() => (regs.d + _fetch8() + regs.y).mask16;
  int _idp() => regs.dbr.shl16 | _ptr16(_dp());
  int _idpX() => regs.dbr.shl16 | _ptr16(_dpX());
  int _idpY() => (regs.dbr.shl16 | _ptr16(_dp())).inc24(regs.y);
  int _ildp() => _ptr24(_dp());
  int _ildpY() => _ptr24(_dp()).inc24(regs.y);
  int _abs() => regs.dbr.shl16 | _fetch16();
  int _absX() => (regs.dbr.shl16 | _fetch16()).inc24(regs.x);
  int _absY() => (regs.dbr.shl16 | _fetch16()).inc24(regs.y);
  int _long() => _fetch24();
  int _longX() => _fetch24().inc24(regs.x);
  int _sr() => (regs.s + _fetch8()).mask16;
  int _srY() => (regs.dbr.shl16 | _ptr16(_sr())).inc24(regs.y);

  // ---------------------------------------------------------------- flags
  @pragma('vm:prefer-inline')
  void _setNZ(int v, int size) {
    final n = size == 1 ? v.bit7 : v.bit15;
    final z = (size == 1 ? v.mask8 : v.mask16) == 0;
    regs.p = (regs.p & ~(Flags.N | Flags.Z)) |
        (n ? Flags.N : 0) |
        (z ? Flags.Z : 0);
  }

  @pragma('vm:prefer-inline')
  void _setFlag(int flag, bool on) =>
      regs.p = on ? regs.p | flag : regs.p & ~flag;

  int get _carry => regs.p & Flags.C;

  // --------------------------------------------------------------- ALU ops
  void _adc(int v) {
    final size = mSize;
    final a = _a;
    if (regs.p.bit3) {
      // decimal
      int lo = (a & 0x0f) + (v & 0x0f) + _carry;
      if (lo > 0x09) lo += 0x06;
      int hi = (a.shr4 & 0x0f) + (v.shr4 & 0x0f) + (lo > 0x0f ? 1 : 0);
      if (hi > 0x09) hi += 0x06;
      int r = (hi.shl4 & 0xf0) | (lo & 0x0f);
      if (size == 2) {
        int hi2 = (a.shr8 & 0x0f) + (v.shr8 & 0x0f) + (hi > 0x0f ? 1 : 0);
        if (hi2 > 0x09) hi2 += 0x06;
        int hi3 = (a.shr12 & 0x0f) + (v.shr12 & 0x0f) + (hi2 > 0x0f ? 1 : 0);
        if (hi3 > 0x09) hi3 += 0x06;
        r |= (hi2.shl8 & 0x0f00) | (hi3.shl12 & 0xf000);
        _setFlag(Flags.C, hi3 > 0x0f);
      } else {
        _setFlag(Flags.C, hi > 0x0f);
      }
      _setA(r);
      _setNZ(r, size);
      return;
    }
    final max = size == 1 ? 0xff : 0xffff;
    final msb = size == 1 ? 0x80 : 0x8000;
    final r = a + v + _carry;
    _setFlag(Flags.V, (~(a ^ v) & (a ^ r) & msb) != 0);
    _setFlag(Flags.C, r > max);
    _setA(r & max);
    _setNZ(r, size);
  }

  void _sbc(int v) {
    final size = mSize;
    if (regs.p.bit3) {
      final a = _a;
      final c = _carry;
      int lo = (a & 0x0f) - (v & 0x0f) + c - 1;
      int hi = (a.shr4 & 0x0f) - (v.shr4 & 0x0f) - (lo < 0 ? 1 : 0);
      if (lo < 0) lo += 0x0a;
      int borrowHi = hi < 0 ? 1 : 0;
      if (hi < 0) hi += 0x0a;
      int r = (hi.shl4 & 0xf0) | (lo & 0x0f);
      if (size == 2) {
        int hi2 = (a.shr8 & 0x0f) - (v.shr8 & 0x0f) - borrowHi;
        int borrow2 = hi2 < 0 ? 1 : 0;
        if (hi2 < 0) hi2 += 0x0a;
        int hi3 = (a.shr12 & 0x0f) - (v.shr12 & 0x0f) - borrow2;
        int borrow3 = hi3 < 0 ? 1 : 0;
        if (hi3 < 0) hi3 += 0x0a;
        r |= (hi2.shl8 & 0x0f00) | (hi3.shl12 & 0xf000);
        _setFlag(Flags.C, borrow3 == 0);
      } else {
        _setFlag(Flags.C, borrowHi == 0);
      }
      _setA(r);
      _setNZ(r, size);
      return;
    }
    // binary subtract = adc of one's complement
    final max = size == 1 ? 0xff : 0xffff;
    _adc(v ^ max);
  }

  void _cmp(int reg, int v, int size) {
    final r = reg - v;
    _setFlag(Flags.C, reg >= v);
    _setNZ(r & (size == 1 ? 0xff : 0xffff), size);
  }

  void _bit(int v, int size, {bool imm = false}) {
    _setFlag(Flags.Z, (_a & v) == 0);
    if (!imm) {
      _setFlag(Flags.N, size == 1 ? v.bit7 : v.bit15);
      _setFlag(Flags.V, size == 1 ? v.bit6 : v.bit14);
    }
  }

  int _asl(int v, int size) {
    final r = v.shl1;
    _setFlag(Flags.C, size == 1 ? v.bit7 : v.bit15);
    _setNZ(r, size);
    return r & (size == 1 ? 0xff : 0xffff);
  }

  int _lsr(int v, int size) {
    _setFlag(Flags.C, v.bit0);
    final r = v.shr1;
    _setNZ(r, size);
    return r;
  }

  int _rol(int v, int size) {
    final r = v.shl1 | _carry;
    _setFlag(Flags.C, size == 1 ? v.bit7 : v.bit15);
    _setNZ(r, size);
    return r & (size == 1 ? 0xff : 0xffff);
  }

  int _ror(int v, int size) {
    final c = _carry;
    _setFlag(Flags.C, v.bit0);
    final r = v.shr1 | (c != 0 ? (size == 1 ? 0x80 : 0x8000) : 0);
    _setNZ(r, size);
    return r;
  }

  // read-modify-write on memory
  void _rmw(int addr, int size, int Function(int, int) op) {
    final v = _read(addr, size);
    _write(addr, op(v, size), size);
  }

  void _branch(bool cond) {
    final offset = _fetch8().rel8;
    if (cond) {
      regs.pc = (regs.pc + offset).mask16;
      cycle += 1;
    }
    cycle += 2;
  }

  // ------------------------------------------------------------ interrupts
  bool _holdNmi = false;
  bool _holdIrq = false;

  void onNmi() => _holdNmi = true;
  void holdIrq() => _holdIrq = true;
  void releaseIrq() => _holdIrq = false;

  void _interrupt(int vectorNative, int vectorEmu, {bool brk = false}) {
    if (!regs.e) _push8(regs.pbr);
    _push16(regs.pc);
    _push8(brk && regs.e ? regs.p | Flags.X : regs.p); // B flag in emu
    _setFlag(Flags.I, true);
    _setFlag(Flags.D, false);
    regs.pbr = 0;
    final v = regs.e ? vectorEmu : vectorNative;
    regs.pc = _read8(v) | _read8(v.inc).shl8;
    cycle += 7;
  }

  void reset() {
    cycle = 0;
    stopped = false;
    waiting = false;
    regs.e = true;
    regs.p = 0x34;
    regs.a = 0;
    regs.x = 0;
    regs.y = 0;
    regs.d = 0;
    regs.dbr = 0;
    regs.pbr = 0;
    regs.s = 0x01ff;
    regs.pc = _read8(0xfffc) | _read8(0xfffd).shl8;
  }

  // ----------------------------------------------------------------- exec
  bool exec() {
    if (stopped) {
      cycle += 1;
      return true;
    }

    if (_holdNmi) {
      _holdNmi = false;
      waiting = false;
      _interrupt(0xffea, 0xfffa);
      return true;
    }

    if (_holdIrq && !regs.p.bit2) {
      waiting = false;
      _interrupt(0xffee, 0xfffe);
      return true;
    }

    if (waiting) {
      cycle += 1;
      return true;
    }

    final op = _fetch8();
    cycle += 2;

    switch (op) {
      // ---------------------------------------------------------- LDA
      case 0xa9:
        _setA(_imm(mSize));
        _setNZ(_a, mSize);
        break;
      case 0xa5:
        _lda(_dp());
        break;
      case 0xb5:
        _lda(_dpX());
        break;
      case 0xb2:
        _lda(_idp());
        break;
      case 0xa1:
        _lda(_idpX());
        break;
      case 0xb1:
        _lda(_idpY());
        break;
      case 0xa7:
        _lda(_ildp());
        break;
      case 0xb7:
        _lda(_ildpY());
        break;
      case 0xad:
        _lda(_abs());
        break;
      case 0xbd:
        _lda(_absX());
        break;
      case 0xb9:
        _lda(_absY());
        break;
      case 0xaf:
        _lda(_long());
        break;
      case 0xbf:
        _lda(_longX());
        break;
      case 0xa3:
        _lda(_sr());
        break;
      case 0xb3:
        _lda(_srY());
        break;

      // ---------------------------------------------------------- LDX
      case 0xa2:
        _setX(_imm(xSize));
        _setNZ(regs.x, xSize);
        break;
      case 0xa6:
        _ldx(_dp());
        break;
      case 0xb6:
        _ldx(_dpY());
        break;
      case 0xae:
        _ldx(_abs());
        break;
      case 0xbe:
        _ldx(_absY());
        break;

      // ---------------------------------------------------------- LDY
      case 0xa0:
        _setY(_imm(xSize));
        _setNZ(regs.y, xSize);
        break;
      case 0xa4:
        _ldy(_dp());
        break;
      case 0xb4:
        _ldy(_dpX());
        break;
      case 0xac:
        _ldy(_abs());
        break;
      case 0xbc:
        _ldy(_absX());
        break;

      // ---------------------------------------------------------- STA
      case 0x85:
        _write(_dp(), _a, mSize);
        break;
      case 0x95:
        _write(_dpX(), _a, mSize);
        break;
      case 0x92:
        _write(_idp(), _a, mSize);
        break;
      case 0x81:
        _write(_idpX(), _a, mSize);
        break;
      case 0x91:
        _write(_idpY(), _a, mSize);
        break;
      case 0x87:
        _write(_ildp(), _a, mSize);
        break;
      case 0x97:
        _write(_ildpY(), _a, mSize);
        break;
      case 0x8d:
        _write(_abs(), _a, mSize);
        break;
      case 0x9d:
        _write(_absX(), _a, mSize);
        break;
      case 0x99:
        _write(_absY(), _a, mSize);
        break;
      case 0x8f:
        _write(_long(), _a, mSize);
        break;
      case 0x9f:
        _write(_longX(), _a, mSize);
        break;
      case 0x83:
        _write(_sr(), _a, mSize);
        break;
      case 0x93:
        _write(_srY(), _a, mSize);
        break;

      // ---------------------------------------------------------- STX/STY
      case 0x86:
        _write(_dp(), regs.x, xSize);
        break;
      case 0x96:
        _write(_dpY(), regs.x, xSize);
        break;
      case 0x8e:
        _write(_abs(), regs.x, xSize);
        break;
      case 0x84:
        _write(_dp(), regs.y, xSize);
        break;
      case 0x94:
        _write(_dpX(), regs.y, xSize);
        break;
      case 0x8c:
        _write(_abs(), regs.y, xSize);
        break;

      // ---------------------------------------------------------- STZ
      case 0x64:
        _write(_dp(), 0, mSize);
        break;
      case 0x74:
        _write(_dpX(), 0, mSize);
        break;
      case 0x9c:
        _write(_abs(), 0, mSize);
        break;
      case 0x9e:
        _write(_absX(), 0, mSize);
        break;

      // ---------------------------------------------------------- ADC
      case 0x69:
        _adc(_imm(mSize));
        break;
      case 0x65:
        _adc(_read(_dp(), mSize));
        break;
      case 0x75:
        _adc(_read(_dpX(), mSize));
        break;
      case 0x72:
        _adc(_read(_idp(), mSize));
        break;
      case 0x61:
        _adc(_read(_idpX(), mSize));
        break;
      case 0x71:
        _adc(_read(_idpY(), mSize));
        break;
      case 0x67:
        _adc(_read(_ildp(), mSize));
        break;
      case 0x77:
        _adc(_read(_ildpY(), mSize));
        break;
      case 0x6d:
        _adc(_read(_abs(), mSize));
        break;
      case 0x7d:
        _adc(_read(_absX(), mSize));
        break;
      case 0x79:
        _adc(_read(_absY(), mSize));
        break;
      case 0x6f:
        _adc(_read(_long(), mSize));
        break;
      case 0x7f:
        _adc(_read(_longX(), mSize));
        break;
      case 0x63:
        _adc(_read(_sr(), mSize));
        break;
      case 0x73:
        _adc(_read(_srY(), mSize));
        break;

      // ---------------------------------------------------------- SBC
      case 0xe9:
        _sbc(_imm(mSize));
        break;
      case 0xe5:
        _sbc(_read(_dp(), mSize));
        break;
      case 0xf5:
        _sbc(_read(_dpX(), mSize));
        break;
      case 0xf2:
        _sbc(_read(_idp(), mSize));
        break;
      case 0xe1:
        _sbc(_read(_idpX(), mSize));
        break;
      case 0xf1:
        _sbc(_read(_idpY(), mSize));
        break;
      case 0xe7:
        _sbc(_read(_ildp(), mSize));
        break;
      case 0xf7:
        _sbc(_read(_ildpY(), mSize));
        break;
      case 0xed:
        _sbc(_read(_abs(), mSize));
        break;
      case 0xfd:
        _sbc(_read(_absX(), mSize));
        break;
      case 0xf9:
        _sbc(_read(_absY(), mSize));
        break;
      case 0xef:
        _sbc(_read(_long(), mSize));
        break;
      case 0xff:
        _sbc(_read(_longX(), mSize));
        break;
      case 0xe3:
        _sbc(_read(_sr(), mSize));
        break;
      case 0xf3:
        _sbc(_read(_srY(), mSize));
        break;

      // ---------------------------------------------------------- AND
      case 0x29:
        _setA(_a & _imm(mSize));
        _setNZ(_a, mSize);
        break;
      case 0x25:
        _and(_read(_dp(), mSize));
        break;
      case 0x35:
        _and(_read(_dpX(), mSize));
        break;
      case 0x32:
        _and(_read(_idp(), mSize));
        break;
      case 0x21:
        _and(_read(_idpX(), mSize));
        break;
      case 0x31:
        _and(_read(_idpY(), mSize));
        break;
      case 0x27:
        _and(_read(_ildp(), mSize));
        break;
      case 0x37:
        _and(_read(_ildpY(), mSize));
        break;
      case 0x2d:
        _and(_read(_abs(), mSize));
        break;
      case 0x3d:
        _and(_read(_absX(), mSize));
        break;
      case 0x39:
        _and(_read(_absY(), mSize));
        break;
      case 0x2f:
        _and(_read(_long(), mSize));
        break;
      case 0x3f:
        _and(_read(_longX(), mSize));
        break;
      case 0x23:
        _and(_read(_sr(), mSize));
        break;
      case 0x33:
        _and(_read(_srY(), mSize));
        break;

      // ---------------------------------------------------------- ORA
      case 0x09:
        _setA(_a | _imm(mSize));
        _setNZ(_a, mSize);
        break;
      case 0x05:
        _ora(_read(_dp(), mSize));
        break;
      case 0x15:
        _ora(_read(_dpX(), mSize));
        break;
      case 0x12:
        _ora(_read(_idp(), mSize));
        break;
      case 0x01:
        _ora(_read(_idpX(), mSize));
        break;
      case 0x11:
        _ora(_read(_idpY(), mSize));
        break;
      case 0x07:
        _ora(_read(_ildp(), mSize));
        break;
      case 0x17:
        _ora(_read(_ildpY(), mSize));
        break;
      case 0x0d:
        _ora(_read(_abs(), mSize));
        break;
      case 0x1d:
        _ora(_read(_absX(), mSize));
        break;
      case 0x19:
        _ora(_read(_absY(), mSize));
        break;
      case 0x0f:
        _ora(_read(_long(), mSize));
        break;
      case 0x1f:
        _ora(_read(_longX(), mSize));
        break;
      case 0x03:
        _ora(_read(_sr(), mSize));
        break;
      case 0x13:
        _ora(_read(_srY(), mSize));
        break;

      // ---------------------------------------------------------- EOR
      case 0x49:
        _setA(_a ^ _imm(mSize));
        _setNZ(_a, mSize);
        break;
      case 0x45:
        _eor(_read(_dp(), mSize));
        break;
      case 0x55:
        _eor(_read(_dpX(), mSize));
        break;
      case 0x52:
        _eor(_read(_idp(), mSize));
        break;
      case 0x41:
        _eor(_read(_idpX(), mSize));
        break;
      case 0x51:
        _eor(_read(_idpY(), mSize));
        break;
      case 0x47:
        _eor(_read(_ildp(), mSize));
        break;
      case 0x57:
        _eor(_read(_ildpY(), mSize));
        break;
      case 0x4d:
        _eor(_read(_abs(), mSize));
        break;
      case 0x5d:
        _eor(_read(_absX(), mSize));
        break;
      case 0x59:
        _eor(_read(_absY(), mSize));
        break;
      case 0x4f:
        _eor(_read(_long(), mSize));
        break;
      case 0x5f:
        _eor(_read(_longX(), mSize));
        break;
      case 0x43:
        _eor(_read(_sr(), mSize));
        break;
      case 0x53:
        _eor(_read(_srY(), mSize));
        break;

      // ---------------------------------------------------------- CMP
      case 0xc9:
        _cmp(_a, _imm(mSize), mSize);
        break;
      case 0xc5:
        _cmp(_a, _read(_dp(), mSize), mSize);
        break;
      case 0xd5:
        _cmp(_a, _read(_dpX(), mSize), mSize);
        break;
      case 0xd2:
        _cmp(_a, _read(_idp(), mSize), mSize);
        break;
      case 0xc1:
        _cmp(_a, _read(_idpX(), mSize), mSize);
        break;
      case 0xd1:
        _cmp(_a, _read(_idpY(), mSize), mSize);
        break;
      case 0xc7:
        _cmp(_a, _read(_ildp(), mSize), mSize);
        break;
      case 0xd7:
        _cmp(_a, _read(_ildpY(), mSize), mSize);
        break;
      case 0xcd:
        _cmp(_a, _read(_abs(), mSize), mSize);
        break;
      case 0xdd:
        _cmp(_a, _read(_absX(), mSize), mSize);
        break;
      case 0xd9:
        _cmp(_a, _read(_absY(), mSize), mSize);
        break;
      case 0xcf:
        _cmp(_a, _read(_long(), mSize), mSize);
        break;
      case 0xdf:
        _cmp(_a, _read(_longX(), mSize), mSize);
        break;
      case 0xc3:
        _cmp(_a, _read(_sr(), mSize), mSize);
        break;
      case 0xd3:
        _cmp(_a, _read(_srY(), mSize), mSize);
        break;

      // ---------------------------------------------------------- CPX/CPY
      case 0xe0:
        _cmp(regs.x, _imm(xSize), xSize);
        break;
      case 0xe4:
        _cmp(regs.x, _read(_dp(), xSize), xSize);
        break;
      case 0xec:
        _cmp(regs.x, _read(_abs(), xSize), xSize);
        break;
      case 0xc0:
        _cmp(regs.y, _imm(xSize), xSize);
        break;
      case 0xc4:
        _cmp(regs.y, _read(_dp(), xSize), xSize);
        break;
      case 0xcc:
        _cmp(regs.y, _read(_abs(), xSize), xSize);
        break;

      // ---------------------------------------------------------- BIT
      case 0x89:
        _bit(_imm(mSize), mSize, imm: true);
        break;
      case 0x24:
        _bit(_read(_dp(), mSize), mSize);
        break;
      case 0x34:
        _bit(_read(_dpX(), mSize), mSize);
        break;
      case 0x2c:
        _bit(_read(_abs(), mSize), mSize);
        break;
      case 0x3c:
        _bit(_read(_absX(), mSize), mSize);
        break;

      // ---------------------------------------------------------- INC/DEC
      case 0x1a: // INC A
        _setA(_a.inc);
        _setNZ(_a, mSize);
        break;
      case 0x3a: // DEC A
        _setA(_a.dec & (mSize == 1 ? 0xff : 0xffff));
        _setNZ(_a, mSize);
        break;
      case 0xe6:
        _rmwInc(_dp());
        break;
      case 0xf6:
        _rmwInc(_dpX());
        break;
      case 0xee:
        _rmwInc(_abs());
        break;
      case 0xfe:
        _rmwInc(_absX());
        break;
      case 0xc6:
        _rmwDec(_dp());
        break;
      case 0xd6:
        _rmwDec(_dpX());
        break;
      case 0xce:
        _rmwDec(_abs());
        break;
      case 0xde:
        _rmwDec(_absX());
        break;

      case 0xe8: // INX
        _setX(regs.x.inc);
        _setNZ(regs.x, xSize);
        break;
      case 0xc8: // INY
        _setY(regs.y.inc);
        _setNZ(regs.y, xSize);
        break;
      case 0xca: // DEX
        _setX(regs.x.dec & (xSize == 1 ? 0xff : 0xffff));
        _setNZ(regs.x, xSize);
        break;
      case 0x88: // DEY
        _setY(regs.y.dec & (xSize == 1 ? 0xff : 0xffff));
        _setNZ(regs.y, xSize);
        break;

      // ---------------------------------------------------------- shifts
      case 0x0a:
        _setA(_asl(_a, mSize));
        break;
      case 0x06:
        _rmw(_dp(), mSize, _asl);
        break;
      case 0x16:
        _rmw(_dpX(), mSize, _asl);
        break;
      case 0x0e:
        _rmw(_abs(), mSize, _asl);
        break;
      case 0x1e:
        _rmw(_absX(), mSize, _asl);
        break;
      case 0x4a:
        _setA(_lsr(_a, mSize));
        break;
      case 0x46:
        _rmw(_dp(), mSize, _lsr);
        break;
      case 0x56:
        _rmw(_dpX(), mSize, _lsr);
        break;
      case 0x4e:
        _rmw(_abs(), mSize, _lsr);
        break;
      case 0x5e:
        _rmw(_absX(), mSize, _lsr);
        break;
      case 0x2a:
        _setA(_rol(_a, mSize));
        break;
      case 0x26:
        _rmw(_dp(), mSize, _rol);
        break;
      case 0x36:
        _rmw(_dpX(), mSize, _rol);
        break;
      case 0x2e:
        _rmw(_abs(), mSize, _rol);
        break;
      case 0x3e:
        _rmw(_absX(), mSize, _rol);
        break;
      case 0x6a:
        _setA(_ror(_a, mSize));
        break;
      case 0x66:
        _rmw(_dp(), mSize, _ror);
        break;
      case 0x76:
        _rmw(_dpX(), mSize, _ror);
        break;
      case 0x6e:
        _rmw(_abs(), mSize, _ror);
        break;
      case 0x7e:
        _rmw(_absX(), mSize, _ror);
        break;

      // ---------------------------------------------------------- TSB/TRB
      case 0x04:
        _trsb(_dp(), set: true);
        break;
      case 0x0c:
        _trsb(_abs(), set: true);
        break;
      case 0x14:
        _trsb(_dp(), set: false);
        break;
      case 0x1c:
        _trsb(_abs(), set: false);
        break;

      // ---------------------------------------------------------- branches
      case 0x90:
        _branch(_carry == 0);
        break;
      case 0xb0:
        _branch(_carry != 0);
        break;
      case 0xd0:
        _branch(!regs.p.bit1);
        break;
      case 0xf0:
        _branch(regs.p.bit1);
        break;
      case 0x10:
        _branch(!regs.p.bit7);
        break;
      case 0x30:
        _branch(regs.p.bit7);
        break;
      case 0x50:
        _branch(!regs.p.bit6);
        break;
      case 0x70:
        _branch(regs.p.bit6);
        break;
      case 0x80: // BRA
        _branch(true);
        break;
      case 0x82: // BRL
        final offset = _fetch16().rel16;
        regs.pc = (regs.pc + offset).mask16;
        cycle += 3;
        break;

      // ---------------------------------------------------------- jumps
      case 0x4c: // JMP abs
        regs.pc = _fetch16();
        break;
      case 0x6c: // JMP (abs)
        regs.pc = _ptr16(_fetch16());
        break;
      case 0x7c: // JMP (abs,X)
        regs.pc = _ptr16Pbr((_fetch16() + regs.x).mask16);
        break;
      case 0x5c: // JML long
        final a = _fetch24();
        regs.pc = a.mask16;
        regs.pbr = a.shr16;
        break;
      case 0xdc: // JML [abs]
        final a = _ptr24(_fetch16());
        regs.pc = a.mask16;
        regs.pbr = a.shr16;
        break;

      case 0x20: // JSR abs
        final a = _fetch16();
        _push16(regs.pc.dec.mask16);
        regs.pc = a;
        cycle += 4;
        break;
      case 0xfc: // JSR (abs,X)
        final ptr = (_fetch16() + regs.x).mask16;
        _push16(regs.pc.dec.mask16);
        regs.pc = _ptr16Pbr(ptr);
        cycle += 5;
        break;
      case 0x22: // JSL long
        final a = _fetch24();
        _push8(regs.pbr);
        _push16(regs.pc.dec.mask16);
        regs.pbr = a.shr16;
        regs.pc = a.mask16;
        cycle += 6;
        break;
      case 0x60: // RTS
        regs.pc = _pull16().inc.mask16;
        cycle += 4;
        break;
      case 0x6b: // RTL
        regs.pc = _pull16().inc.mask16;
        regs.pbr = _pull8();
        cycle += 4;
        break;
      case 0x40: // RTI
        regs.p = _pull8();
        regs.pc = _pull16();
        if (!regs.e) regs.pbr = _pull8();
        cycle += 5;
        break;

      // ---------------------------------------------------------- stack
      case 0x48: // PHA
        _pushReg(_a, mSize);
        break;
      case 0xda: // PHX
        _pushReg(regs.x, xSize);
        break;
      case 0x5a: // PHY
        _pushReg(regs.y, xSize);
        break;
      case 0x08: // PHP
        _push8(regs.p);
        break;
      case 0x0b: // PHD
        _push16(regs.d);
        break;
      case 0x8b: // PHB
        _push8(regs.dbr);
        break;
      case 0x4b: // PHK
        _push8(regs.pbr);
        break;
      case 0xf4: // PEA
        _push16(_fetch16());
        break;
      case 0xd4: // PEI
        _push16(_ptr16(_dp()));
        break;
      case 0x62: // PER
        final disp = _fetch16().rel16;
        _push16((regs.pc + disp).mask16);
        break;
      case 0x68: // PLA
        _setA(_pullReg(mSize));
        _setNZ(_a, mSize);
        break;
      case 0xfa: // PLX
        _setX(_pullReg(xSize));
        _setNZ(regs.x, xSize);
        break;
      case 0x7a: // PLY
        _setY(_pullReg(xSize));
        _setNZ(regs.y, xSize);
        break;
      case 0x28: // PLP
        regs.p = _pull8();
        _normalizeWidths();
        break;
      case 0x2b: // PLD
        regs.d = _pull16();
        _setNZ(regs.d, 2);
        break;
      case 0xab: // PLB
        regs.dbr = _pull8();
        _setNZ(regs.dbr, 1);
        break;

      // ---------------------------------------------------------- transfers
      case 0xaa: // TAX
        _setX(regs.a);
        _setNZ(regs.x, xSize);
        break;
      case 0xa8: // TAY
        _setY(regs.a);
        _setNZ(regs.y, xSize);
        break;
      case 0x8a: // TXA
        _setA(regs.x);
        _setNZ(_a, mSize);
        break;
      case 0x98: // TYA
        _setA(regs.y);
        _setNZ(_a, mSize);
        break;
      case 0x9b: // TXY
        _setY(regs.x);
        _setNZ(regs.y, xSize);
        break;
      case 0xbb: // TYX
        _setX(regs.y);
        _setNZ(regs.x, xSize);
        break;
      case 0xba: // TSX
        _setX(regs.s);
        _setNZ(regs.x, xSize);
        break;
      case 0x9a: // TXS
        regs.s = regs.e ? 0x0100 | regs.x.mask8 : regs.x.mask16;
        break;
      case 0x5b: // TCD
        regs.d = regs.a.mask16;
        _setNZ(regs.d, 2);
        break;
      case 0x7b: // TDC
        regs.a = regs.d.mask16;
        _setNZ(regs.a, 2);
        break;
      case 0x1b: // TCS
        regs.s = regs.e ? 0x0100 | regs.a.mask8 : regs.a.mask16;
        break;
      case 0x3b: // TSC
        regs.a = regs.s.mask16;
        _setNZ(regs.a, 2);
        break;

      // ---------------------------------------------------------- flags
      case 0x18:
        _setFlag(Flags.C, false);
        break;
      case 0x38:
        _setFlag(Flags.C, true);
        break;
      case 0x58:
        _setFlag(Flags.I, false);
        break;
      case 0x78:
        _setFlag(Flags.I, true);
        break;
      case 0xd8:
        _setFlag(Flags.D, false);
        break;
      case 0xf8:
        _setFlag(Flags.D, true);
        break;
      case 0xb8:
        _setFlag(Flags.V, false);
        break;
      case 0xc2: // REP
        regs.p &= ~_fetch8();
        _normalizeWidths();
        break;
      case 0xe2: // SEP
        regs.p |= _fetch8();
        _normalizeWidths();
        break;
      case 0xfb: // XCE
        final c = regs.p.bit0;
        _setFlag(Flags.C, regs.e);
        regs.e = c;
        if (regs.e) {
          regs.p |= Flags.M | Flags.X;
          regs.s = 0x0100 | regs.s.mask8;
        }
        _normalizeWidths();
        break;

      // ---------------------------------------------------------- misc
      case 0xeb: // XBA
        regs.a = (regs.a.shl8 | regs.a.shr8).mask16;
        _setNZ(regs.a.mask8, 1);
        break;
      case 0xea: // NOP
        break;
      case 0x42: // WDM
        _fetch8();
        break;
      case 0xcb: // WAI
        waiting = true;
        break;
      case 0xdb: // STP
        stopped = true;
        break;

      case 0x54: // MVN
        _blockMove(inc: true);
        break;
      case 0x44: // MVP
        _blockMove(inc: false);
        break;

      case 0x00: // BRK
        _fetch8();
        _interrupt(0xffe6, 0xfffe, brk: true);
        break;
      case 0x02: // COP
        _fetch8();
        _interrupt(0xffe4, 0xfff4);
        break;

      default:
        log("65816: unimplemented opcode ${op.x2} at "
            "${regs.pbr.x2}:${regs.pc.dec.mask16.x4}");
        return false;
    }

    return true;
  }

  // ----------------------------------------------------------- op helpers
  int _imm(int size) => size == 1 ? _fetch8() : _fetch16();

  void _lda(int addr) {
    _setA(_read(addr, mSize));
    _setNZ(_a, mSize);
  }

  void _ldx(int addr) {
    _setX(_read(addr, xSize));
    _setNZ(regs.x, xSize);
  }

  void _ldy(int addr) {
    _setY(_read(addr, xSize));
    _setNZ(regs.y, xSize);
  }

  void _and(int v) {
    _setA(_a & v);
    _setNZ(_a, mSize);
  }

  void _ora(int v) {
    _setA(_a | v);
    _setNZ(_a, mSize);
  }

  void _eor(int v) {
    _setA(_a ^ v);
    _setNZ(_a, mSize);
  }

  void _rmwInc(int addr) {
    final size = mSize;
    final v = (_read(addr, size).inc) & (size == 1 ? 0xff : 0xffff);
    _write(addr, v, size);
    _setNZ(v, size);
  }

  void _rmwDec(int addr) {
    final size = mSize;
    final v = (_read(addr, size).dec) & (size == 1 ? 0xff : 0xffff);
    _write(addr, v, size);
    _setNZ(v, size);
  }

  void _trsb(int addr, {required bool set}) {
    final size = mSize;
    final v = _read(addr, size);
    _setFlag(Flags.Z, (_a & v) == 0);
    _write(addr, set ? v | _a : v & ~_a, size);
  }

  void _pushReg(int v, int size) {
    if (size == 2) _push8(v.shr8);
    _push8(v.mask8);
  }

  int _pullReg(int size) => size == 1 ? _pull8() : _pull16();

  void _normalizeWidths() {
    if (regs.e) regs.p |= Flags.M | Flags.X;
    if (regs.p.bit4) {
      // 8-bit index: high bytes cleared
      regs.x = regs.x.mask8;
      regs.y = regs.y.mask8;
    }
  }

  void _blockMove({required bool inc}) {
    final destBank = _fetch8();
    final srcBank = _fetch8();
    regs.dbr = destBank;
    final step = inc ? 1 : -1;
    while (regs.a.mask16 != 0xffff) {
      final v = _read8(srcBank.shl16 | regs.x.mask16);
      _write8(destBank.shl16 | regs.y.mask16, v);
      regs.x = (regs.x + step).mask16;
      regs.y = (regs.y + step).mask16;
      regs.a = regs.a.dec.mask16;
      cycle += 7;
    }
    if (xSize == 1) {
      regs.x = regs.x.mask8;
      regs.y = regs.y.mask8;
    }
  }
}

extension on int {
  /// 24-bit address add (data-bank crossing carry, no wrap)
  @pragma('vm:prefer-inline')
  int inc24(int offset) => (this + offset).mask24;
}
