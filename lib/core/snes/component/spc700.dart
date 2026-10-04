import 'package:fnesemu/util/int.dart';

import 'dsp.dart';

/// the 64-byte IPL boot ROM, identical on every SNES unit. Handles the
/// handshake that lets the main CPU upload an audio driver over $2140-2143.
/// verified against bsnes-mercury's iplrom[] (a widely-used accurate core).
const iplRom = <int>[
  0xcd, 0xef, 0xbd, 0xe8, 0x00, 0xc6, 0x1d, 0xd0, //
  0xfc, 0x8f, 0xaa, 0xf4, 0x8f, 0xbb, 0xf5, 0x78, //
  0xcc, 0xf4, 0xd0, 0xfb, 0x2f, 0x19, 0xeb, 0xf4, //
  0xd0, 0xfc, 0x7e, 0xf4, 0xd0, 0x0b, 0xe4, 0xf5, //
  0xcb, 0xf4, 0xd7, 0x00, 0xfc, 0xd0, 0xf3, 0xab, //
  0x01, 0x10, 0xef, 0x7e, 0xf4, 0x10, 0xeb, 0xba, //
  0xf6, 0xda, 0x00, 0xba, 0xf4, 0xc4, 0xf4, 0xdd, //
  0x5d, 0xd0, 0xdb, 0x1f, 0x00, 0x00, 0xc0, 0xff, //
];

class Flags {
  static const n = 0x80;
  static const v = 0x40;
  static const p = 0x20;
  static const b = 0x10;
  static const h = 0x08;
  static const i = 0x04;
  static const z = 0x02;
  static const c = 0x01;
}

/// SPC700 CPU + its 64KB RAM + I/O register file ($F0-$FF) + timers.
///
/// Communicates with the main 65816 via 4 port bytes at $F4-$F7 (mirrored
/// at $2140-2143 on the SNES side; see Bus/Snes wiring). Not cycle-exact:
/// each instruction advances [cycle] by an approximate count.
class Spc700 {
  Spc700(this.dsp) {
    dsp.spc = this;
    reset();
  }

  final Dsp dsp;

  final ram = List<int>.filled(0x10000, 0);

  int a = 0, x = 0, y = 0, sp = 0xef, psw = 0x02, pc = 0xffc0;
  int cycle = 0;

  // CPU<->SPC ports: portIn = what the main CPU wrote (SPC reads $F4-F7),
  // portOut = what the SPC wrote (main CPU reads $2140-2143).
  final portIn = List<int>.filled(4, 0);
  final portOut = List<int>.filled(4, 0);

  // I/O registers
  int test = 0x0a;
  int control = 0xb0; // bit7 = IPL ROM enabled
  int dspAddr = 0;
  final timerTarget = List<int>.filled(3, 0); // $FA-FC
  final timerOut = List<int>.filled(3, 0); // $FD-FF, 4-bit, read-clears
  final _timerEnabled = List<bool>.filled(3, false);
  final _timerDiv = List<int>.filled(3, 0); // stage-1 prescaler counter

  void reset() {
    a = 0;
    x = 0;
    y = 0;
    sp = 0xef;
    psw = 0x02;
    pc = 0xffc0;
    cycle = 0;
    test = 0x0a;
    control = 0xb0;
    dspAddr = 0;
    for (int i = 0; i < 4; i++) {
      portIn[i] = 0;
      portOut[i] = 0;
    }
    for (int i = 0; i < 3; i++) {
      timerTarget[i] = 0;
      timerOut[i] = 0;
      _timerEnabled[i] = false;
      _timerDiv[i] = 0;
      _stage2[i] = 0;
    }
  }

  // -------------------------------------------------------------- memory
  int read(int addr) {
    addr &= 0xffff;
    if (addr >= 0xffc0 && control.bit7) return iplRom[addr - 0xffc0];
    if (addr >= 0xf0 && addr <= 0xff) return _readIo(addr - 0xf0);
    return ram[addr];
  }

  void write(int addr, int val) {
    addr &= 0xffff;
    val &= 0xff;
    if (addr >= 0xf0 && addr <= 0xff) {
      _writeIo(addr - 0xf0, val);
      return; // I/O writes do not also fall through to backing RAM
    }
    ram[addr] = val;
  }

  int _readIo(int r) {
    switch (r) {
      case 0x2: // DSPADDR
        return dspAddr;
      case 0x3: // DSPDATA
        return dsp.read(dspAddr.mask7);
      case 0x4:
      case 0x5:
      case 0x6:
      case 0x7:
        return portIn[r - 4];
      case 0xd:
      case 0xe:
      case 0xf:
        {
          final v = timerOut[r - 0xd].mask4;
          timerOut[r - 0xd] = 0;
          return v;
        }
      case 0x8:
      case 0x9: // AUXIO: plain read/write registers
        return ram[0xf0 + r];
      default:
        return 0; // TEST/CONTROL/timer targets: write-only, read as 0
    }
  }

  void _writeIo(int r, int val) {
    switch (r) {
      case 0x0:
        test = val;
        break;
      case 0x1:
        {
          final wasEnabled = List<bool>.from(_timerEnabled);
          for (int t = 0; t < 3; t++) {
            _timerEnabled[t] = val.bit(t);
            if (_timerEnabled[t] && !wasEnabled[t]) {
              _timerDiv[t] = 0;
              _stage2[t] = 0;
              timerOut[t] = 0;
            }
          }
          if (val.bit4) {
            portIn[0] = 0;
            portIn[1] = 0;
          }
          if (val.bit5) {
            portIn[2] = 0;
            portIn[3] = 0;
          }
          control = val;
        }
        break;
      case 0x2:
        dspAddr = val;
        break;
      case 0x3:
        if (!dspAddr.bit7) dsp.write(dspAddr.mask7, val);
        break;
      case 0x4:
      case 0x5:
      case 0x6:
      case 0x7:
        portOut[r - 4] = val;
        break;
      case 0xa:
      case 0xb:
      case 0xc:
        timerTarget[r - 0xa] = val;
        break;
      default:
        break; // $FD-FF (timer out) are read-only
    }
    ram[0xf0 + r] = val; // registers overlay RAM, like the IPL ROM region
  }

  /// advances the 3 timers by [n] SPC clock cycles (called from exec()).
  void _tickTimers(int n) {
    for (int t = 0; t < 3; t++) {
      if (!_timerEnabled[t]) continue;
      final stage1 = t == 2 ? 16 : 128;
      _timerDiv[t] += n;
      while (_timerDiv[t] >= stage1) {
        _timerDiv[t] -= stage1;
        final target = timerTarget[t] == 0 ? 256 : timerTarget[t];
        // stage2 folded into stage3 directly (documented simplification:
        // real hardware has a separate free-running stage2 counter/compare;
        // here we just tick stage3 every `target` stage-1 ticks)
        _stage2[t]++;
        if (_stage2[t] >= target) {
          _stage2[t] = 0;
          timerOut[t] = (timerOut[t] + 1).mask4;
        }
      }
    }
  }

  final _stage2 = List<int>.filled(3, 0);

  // --------------------------------------------------------------- ports
  /// called by the main bus when the 65816 writes $2140-2143.
  void mainCpuWrite(int port, int val) => portIn[port.mask2] = val.mask8;

  /// called by the main bus when the 65816 reads $2140-2143.
  int mainCpuRead(int port) => portOut[port.mask2];

  // ----------------------------------------------------------- addressing
  int _dpBase() => psw.bit5 ? 0x100 : 0;

  int _fetch8() {
    final v = read(pc);
    pc = pc.inc.mask16;
    return v;
  }

  int _fetch16() => _fetch8() | _fetch8().shl8;

  int _dp() => _dpBase() + _fetch8();
  int _dpX() => _dpBase() + (_fetch8() + x).mask8;
  int _dpY() => _dpBase() + (_fetch8() + y).mask8;
  int _abs() => _fetch16();
  int _absX() => (_fetch16() + x).mask16;
  int _absY() => (_fetch16() + y).mask16;
  int _indX() => _dpBase() + x;
  int _indY() => _dpBase() + y;
  int _indDpX() {
    final p = _dpX();
    return read(p) | read(_dpBase() + (p - _dpBase() + 1).mask8).shl8;
  }

  int _indDpY() {
    final p = _dp();
    final ptr = read(p) | read(_dpBase() + (p - _dpBase() + 1).mask8).shl8;
    return (ptr + y).mask16;
  }

  void _push8(int v) {
    write(0x100 | sp, v);
    sp = sp.dec.mask8;
  }

  int _pull8() {
    sp = sp.inc.mask8;
    return read(0x100 | sp);
  }

  void _setNZ(int v) {
    psw = (psw & ~(Flags.n | Flags.z)) |
        (v.bit7 ? Flags.n : 0) |
        (v.mask8 == 0 ? Flags.z : 0);
  }

  void _setNZ16(int v) {
    psw = (psw & ~(Flags.n | Flags.z)) |
        (v.bit15 ? Flags.n : 0) |
        (v.mask16 == 0 ? Flags.z : 0);
  }

  void _setFlag(int flag, bool on) =>
      psw = on ? (psw | flag) : (psw & ~flag);

  int get _carry => psw & Flags.c;

  // -------------------------------------------------------------- ALU ops
  void _adc(int v) {
    final r = a + v + _carry;
    _setFlag(Flags.h, a.mask4 + v.mask4 + _carry > 0xf);
    _setFlag(Flags.v, (~(a ^ v) & (a ^ r) & 0x80) != 0);
    _setFlag(Flags.c, r > 0xff);
    a = r.mask8;
    _setNZ(a);
  }

  void _sbc(int v) => _adc(v ^ 0xff);

  void _cmp(int reg, int v) {
    final r = reg - v;
    _setFlag(Flags.c, reg >= v);
    _setNZ(r.mask8);
  }

  void _and(int v) {
    a &= v;
    _setNZ(a);
  }

  void _or(int v) {
    a |= v;
    _setNZ(a);
  }

  void _eor(int v) {
    a ^= v;
    _setNZ(a);
  }

  int _asl(int v) {
    _setFlag(Flags.c, v.bit7);
    final r = v.shl1.mask8;
    _setNZ(r);
    return r;
  }

  int _lsr(int v) {
    _setFlag(Flags.c, v.bit0);
    final r = v.shr1;
    _setNZ(r);
    return r;
  }

  int _rol(int v) {
    final r = (v.shl1 | _carry).mask8;
    _setFlag(Flags.c, v.bit7);
    _setNZ(r);
    return r;
  }

  int _ror(int v) {
    final c = _carry;
    _setFlag(Flags.c, v.bit0);
    final r = v.shr1 | (c != 0 ? 0x80 : 0);
    _setNZ(r);
    return r;
  }

  void _branch(bool cond) {
    final offset = _fetch8().rel8;
    cycle += 2;
    if (cond) {
      pc = (pc + offset).mask16;
      cycle += 2;
    }
  }

  // ------------------------------------------------------------- bit ops
  (int, int) _memBit() {
    final w = _fetch16();
    return (w.mask13, w.shr13.mask3);
  }

  // ----------------------------------------------------------------- exec
  bool exec() {
    final op = _fetch8();
    cycle += 2;
    final startCycle = cycle;

    switch (op) {
      case 0x00: // NOP
        break;
      case 0xef: // SLEEP
      case 0xff: // STOP
        pc = pc.dec.mask16; // stall: keep re-fetching the same opcode
        break;

      // ---------------------------------------------------------- MOV A,*
      case 0xe8:
        a = _fetch8();
        _setNZ(a);
        break;
      case 0xe4:
        a = read(_dp());
        _setNZ(a);
        break;
      case 0xf4:
        a = read(_dpX());
        _setNZ(a);
        break;
      case 0xe5:
        a = read(_abs());
        _setNZ(a);
        break;
      case 0xf5:
        a = read(_absX());
        _setNZ(a);
        break;
      case 0xf6:
        a = read(_absY());
        _setNZ(a);
        break;
      case 0xe6:
        a = read(_indX());
        _setNZ(a);
        break;
      case 0xbf:
        {
          final p = _indX();
          a = read(p);
          x = (x + 1).mask8;
          _setNZ(a);
        }
        break;
      case 0xe7:
        a = read(_indDpX());
        _setNZ(a);
        break;
      case 0xf7:
        a = read(_indDpY());
        _setNZ(a);
        break;

      // ---------------------------------------------------------- MOV X,*/Y,*
      case 0xcd:
        x = _fetch8();
        _setNZ(x);
        break;
      case 0xf8:
        x = read(_dp());
        _setNZ(x);
        break;
      case 0xf9:
        x = read(_dpY());
        _setNZ(x);
        break;
      case 0xe9:
        x = read(_abs());
        _setNZ(x);
        break;
      case 0x8d:
        y = _fetch8();
        _setNZ(y);
        break;
      case 0xeb:
        y = read(_dp());
        _setNZ(y);
        break;
      case 0xfb:
        y = read(_dpX());
        _setNZ(y);
        break;
      case 0xec:
        y = read(_abs());
        _setNZ(y);
        break;

      // ---------------------------------------------------------- MOV *,A
      case 0xc4:
        write(_dp(), a);
        break;
      case 0xd4:
        write(_dpX(), a);
        break;
      case 0xc5:
        write(_abs(), a);
        break;
      case 0xd5:
        write(_absX(), a);
        break;
      case 0xd6:
        write(_absY(), a);
        break;
      case 0xc6:
        write(_indX(), a);
        break;
      case 0xaf:
        write(_indX(), a);
        x = (x + 1).mask8;
        break;
      case 0xc7:
        write(_indDpX(), a);
        break;
      case 0xd7:
        write(_indDpY(), a);
        break;

      // ---------------------------------------------------------- MOV *,X/Y
      case 0xd8:
        write(_dp(), x);
        break;
      case 0xd9:
        write(_dpY(), x);
        break;
      case 0xc9:
        write(_abs(), x);
        break;
      case 0xcb:
        write(_dp(), y);
        break;
      case 0xdb:
        write(_dpX(), y);
        break;
      case 0xcc:
        write(_abs(), y);
        break;

      // ---------------------------------------------------------- MOV d,d / d,#i
      case 0xfa:
        {
          final src = read(_dp());
          write(_dp(), src);
        }
        break;
      case 0x8f:
        {
          final imm = _fetch8();
          write(_dp(), imm);
        }
        break;

      // ---------------------------------------------------------- MOV reg,reg
      case 0x7d:
        a = x;
        _setNZ(a);
        break;
      case 0xdd:
        a = y;
        _setNZ(a);
        break;
      case 0x5d:
        x = a;
        _setNZ(x);
        break;
      case 0xfd:
        y = a;
        _setNZ(y);
        break;
      case 0x9d:
        x = sp;
        _setNZ(x);
        break;
      case 0xbd:
        sp = x;
        break;

      // ---------------------------------------------------------- 16-bit MOVW
      case 0xba:
        {
          final p = _dp();
          final lo = read(p);
          final hi = read(_dpBase() + (p - _dpBase() + 1).mask8);
          a = lo;
          y = hi;
          _setNZ16(hi.shl8 | lo);
        }
        break;
      case 0xda:
        {
          final p = _dp();
          write(p, a);
          write(_dpBase() + (p - _dpBase() + 1).mask8, y);
        }
        break;

      // ---------------------------------------------------------- PUSH/POP
      case 0x2d:
        _push8(a);
        cycle += 2;
        break;
      case 0x4d:
        _push8(x);
        cycle += 2;
        break;
      case 0x6d:
        _push8(y);
        cycle += 2;
        break;
      case 0x0d:
        _push8(psw);
        cycle += 2;
        break;
      case 0xae:
        a = _pull8();
        cycle += 2;
        break;
      case 0xce:
        x = _pull8();
        cycle += 2;
        break;
      case 0xee:
        y = _pull8();
        cycle += 2;
        break;
      case 0x8e:
        psw = _pull8();
        cycle += 2;
        break;

      // ---------------------------------------------------------- ALU: OR
      case 0x08:
        _or(_fetch8());
        break;
      case 0x04:
        _or(read(_dp()));
        break;
      case 0x14:
        _or(read(_dpX()));
        break;
      case 0x05:
        _or(read(_abs()));
        break;
      case 0x15:
        _or(read(_absX()));
        break;
      case 0x16:
        _or(read(_absY()));
        break;
      case 0x06:
        _or(read(_indX()));
        break;
      case 0x07:
        _or(read(_indDpX()));
        break;
      case 0x17:
        _or(read(_indDpY()));
        break;
      case 0x19:
        {
          final v = read(_indX()) | read(_indY());
          write(_indX(), v);
          _setNZ(v);
        }
        break;
      case 0x09:
        {
          final src = read(_dp());
          final dst = _dp();
          final v = read(dst) | src;
          write(dst, v);
          _setNZ(v);
        }
        break;
      case 0x18:
        {
          final imm = _fetch8();
          final p = _dp();
          final v = read(p) | imm;
          write(p, v);
          _setNZ(v);
        }
        break;

      // ---------------------------------------------------------- ALU: AND
      case 0x28:
        _and(_fetch8());
        break;
      case 0x24:
        _and(read(_dp()));
        break;
      case 0x34:
        _and(read(_dpX()));
        break;
      case 0x25:
        _and(read(_abs()));
        break;
      case 0x35:
        _and(read(_absX()));
        break;
      case 0x36:
        _and(read(_absY()));
        break;
      case 0x26:
        _and(read(_indX()));
        break;
      case 0x27:
        _and(read(_indDpX()));
        break;
      case 0x37:
        _and(read(_indDpY()));
        break;
      case 0x39:
        {
          final v = read(_indX()) & read(_indY());
          write(_indX(), v);
          _setNZ(v);
        }
        break;
      case 0x29:
        {
          final src = read(_dp());
          final dst = _dp();
          final v = read(dst) & src;
          write(dst, v);
          _setNZ(v);
        }
        break;
      case 0x38:
        {
          final imm = _fetch8();
          final p = _dp();
          final v = read(p) & imm;
          write(p, v);
          _setNZ(v);
        }
        break;

      // ---------------------------------------------------------- ALU: EOR
      case 0x48:
        _eor(_fetch8());
        break;
      case 0x44:
        _eor(read(_dp()));
        break;
      case 0x54:
        _eor(read(_dpX()));
        break;
      case 0x45:
        _eor(read(_abs()));
        break;
      case 0x55:
        _eor(read(_absX()));
        break;
      case 0x56:
        _eor(read(_absY()));
        break;
      case 0x46:
        _eor(read(_indX()));
        break;
      case 0x47:
        _eor(read(_indDpX()));
        break;
      case 0x57:
        _eor(read(_indDpY()));
        break;
      case 0x59:
        {
          final v = read(_indX()) ^ read(_indY());
          write(_indX(), v);
          _setNZ(v);
        }
        break;
      case 0x49:
        {
          final src = read(_dp());
          final dst = _dp();
          final v = read(dst) ^ src;
          write(dst, v);
          _setNZ(v);
        }
        break;
      case 0x58:
        {
          final imm = _fetch8();
          final p = _dp();
          final v = read(p) ^ imm;
          write(p, v);
          _setNZ(v);
        }
        break;

      // ---------------------------------------------------------- ALU: ADC
      case 0x88:
        _adc(_fetch8());
        break;
      case 0x84:
        _adc(read(_dp()));
        break;
      case 0x94:
        _adc(read(_dpX()));
        break;
      case 0x85:
        _adc(read(_abs()));
        break;
      case 0x95:
        _adc(read(_absX()));
        break;
      case 0x96:
        _adc(read(_absY()));
        break;
      case 0x86:
        _adc(read(_indX()));
        break;
      case 0x87:
        _adc(read(_indDpX()));
        break;
      case 0x97:
        _adc(read(_indDpY()));
        break;
      case 0x99: // ADC (X),(Y): result goes to (X)
        {
          final d = _indX();
          final vs = a;
          a = read(d);
          _adc(read(_indY()));
          write(d, a);
          a = vs;
        }
        break;
      case 0x89:
        {
          final s = read(_dp());
          final dst = _dp();
          final vs = a;
          a = read(dst);
          _adc(s);
          write(dst, a);
          a = vs;
        }
        break;
      case 0x98:
        {
          final imm = _fetch8();
          final p = _dp();
          final vs = a;
          a = read(p);
          _adc(imm);
          write(p, a);
          a = vs;
        }
        break;

      // ---------------------------------------------------------- ALU: SBC
      case 0xa8:
        _sbc(_fetch8());
        break;
      case 0xa4:
        _sbc(read(_dp()));
        break;
      case 0xb4:
        _sbc(read(_dpX()));
        break;
      case 0xa5:
        _sbc(read(_abs()));
        break;
      case 0xb5:
        _sbc(read(_absX()));
        break;
      case 0xb6:
        _sbc(read(_absY()));
        break;
      case 0xa6:
        _sbc(read(_indX()));
        break;
      case 0xa7:
        _sbc(read(_indDpX()));
        break;
      case 0xb7:
        _sbc(read(_indDpY()));
        break;
      case 0xb9: // SBC (X),(Y): result goes to (X)
        {
          final d = _indX();
          final vs = a;
          a = read(d);
          _sbc(read(_indY()));
          write(d, a);
          a = vs;
        }
        break;
      case 0xa9:
        {
          final s = read(_dp());
          final dst = _dp();
          final vs = a;
          a = read(dst);
          _sbc(s);
          write(dst, a);
          a = vs;
        }
        break;
      case 0xb8:
        {
          final imm = _fetch8();
          final p = _dp();
          final vs = a;
          a = read(p);
          _sbc(imm);
          write(p, a);
          a = vs;
        }
        break;

      // ---------------------------------------------------------- CMP A
      case 0x68:
        _cmp(a, _fetch8());
        break;
      case 0x64:
        _cmp(a, read(_dp()));
        break;
      case 0x74:
        _cmp(a, read(_dpX()));
        break;
      case 0x65:
        _cmp(a, read(_abs()));
        break;
      case 0x75:
        _cmp(a, read(_absX()));
        break;
      case 0x76:
        _cmp(a, read(_absY()));
        break;
      case 0x66:
        _cmp(a, read(_indX()));
        break;
      case 0x67:
        _cmp(a, read(_indDpX()));
        break;
      case 0x77:
        _cmp(a, read(_indDpY()));
        break;
      case 0x79:
        _cmp(read(_indX()), read(_indY()));
        break;
      case 0x69:
        {
          final s = read(_dp());
          _cmp(read(_dp()), s);
        }
        break;
      case 0x78:
        {
          final imm = _fetch8();
          _cmp(read(_dp()), imm);
        }
        break;
      case 0xc8:
        _cmp(x, _fetch8());
        break;
      case 0x3e:
        _cmp(x, read(_dp()));
        break;
      case 0x1e:
        _cmp(x, read(_abs()));
        break;
      case 0xad:
        _cmp(y, _fetch8());
        break;
      case 0x7e:
        _cmp(y, read(_dp()));
        break;
      case 0x5e:
        _cmp(y, read(_abs()));
        break;

      // ---------------------------------------------------------- shifts (A)
      case 0x1c:
        a = _asl(a);
        break;
      case 0x0b:
        {
          final p = _dp();
          write(p, _asl(read(p)));
        }
        break;
      case 0x1b:
        {
          final p = _dpX();
          write(p, _asl(read(p)));
        }
        break;
      case 0x0c:
        {
          final p = _abs();
          write(p, _asl(read(p)));
        }
        break;
      case 0x5c:
        a = _lsr(a);
        break;
      case 0x4b:
        {
          final p = _dp();
          write(p, _lsr(read(p)));
        }
        break;
      case 0x5b:
        {
          final p = _dpX();
          write(p, _lsr(read(p)));
        }
        break;
      case 0x4c:
        {
          final p = _abs();
          write(p, _lsr(read(p)));
        }
        break;
      case 0x3c:
        a = _rol(a);
        break;
      case 0x2b:
        {
          final p = _dp();
          write(p, _rol(read(p)));
        }
        break;
      case 0x3b:
        {
          final p = _dpX();
          write(p, _rol(read(p)));
        }
        break;
      case 0x2c:
        {
          final p = _abs();
          write(p, _rol(read(p)));
        }
        break;
      case 0x7c:
        a = _ror(a);
        break;
      case 0x6b:
        {
          final p = _dp();
          write(p, _ror(read(p)));
        }
        break;
      case 0x7b:
        {
          final p = _dpX();
          write(p, _ror(read(p)));
        }
        break;
      case 0x6c:
        {
          final p = _abs();
          write(p, _ror(read(p)));
        }
        break;

      // ---------------------------------------------------------- INC/DEC
      case 0xbc:
        a = (a + 1).mask8;
        _setNZ(a);
        break;
      case 0x9c:
        a = (a - 1).mask8;
        _setNZ(a);
        break;
      case 0x3d:
        x = (x + 1).mask8;
        _setNZ(x);
        break;
      case 0x1d:
        x = (x - 1).mask8;
        _setNZ(x);
        break;
      case 0xfc:
        y = (y + 1).mask8;
        _setNZ(y);
        break;
      case 0xdc:
        y = (y - 1).mask8;
        _setNZ(y);
        break;
      case 0xab:
        {
          final p = _dp();
          final v = (read(p) + 1).mask8;
          write(p, v);
          _setNZ(v);
        }
        break;
      case 0xbb:
        {
          final p = _dpX();
          final v = (read(p) + 1).mask8;
          write(p, v);
          _setNZ(v);
        }
        break;
      case 0xac:
        {
          final p = _abs();
          final v = (read(p) + 1).mask8;
          write(p, v);
          _setNZ(v);
        }
        break;
      case 0x8b:
        {
          final p = _dp();
          final v = (read(p) - 1).mask8;
          write(p, v);
          _setNZ(v);
        }
        break;
      case 0x9b:
        {
          final p = _dpX();
          final v = (read(p) - 1).mask8;
          write(p, v);
          _setNZ(v);
        }
        break;
      case 0x8c:
        {
          final p = _abs();
          final v = (read(p) - 1).mask8;
          write(p, v);
          _setNZ(v);
        }
        break;

      // ---------------------------------------------------------- 16-bit INCW/DECW/ADDW/SUBW/CMPW
      case 0x3a:
        {
          final p = _dp();
          final hiAddr = _dpBase() + (p - _dpBase() + 1).mask8;
          final v = ((read(p) | read(hiAddr).shl8) + 1).mask16;
          write(p, v.mask8);
          write(hiAddr, v.shr8);
          _setNZ16(v);
        }
        break;
      case 0x1a:
        {
          final p = _dp();
          final hiAddr = _dpBase() + (p - _dpBase() + 1).mask8;
          final v = ((read(p) | read(hiAddr).shl8) - 1).mask16;
          write(p, v.mask8);
          write(hiAddr, v.shr8);
          _setNZ16(v);
        }
        break;
      case 0x7a:
        {
          final p = _dp();
          final hiAddr = _dpBase() + (p - _dpBase() + 1).mask8;
          final ya = a | y.shl8;
          final operand = read(p) | read(hiAddr).shl8;
          final r = ya + operand;
          _setFlag(Flags.h, ya.mask12 + operand.mask12 > 0xfff);
          _setFlag(Flags.v, (~(ya ^ operand) & (ya ^ r) & 0x8000) != 0);
          _setFlag(Flags.c, r > 0xffff);
          a = r.mask8;
          y = r.shr8.mask8;
          _setNZ16(r.mask16);
        }
        break;
      case 0x9a:
        {
          final p = _dp();
          final hiAddr = _dpBase() + (p - _dpBase() + 1).mask8;
          final ya = a | y.shl8;
          final operand = read(p) | read(hiAddr).shl8;
          final r = ya - operand;
          _setFlag(Flags.h, ya.mask12 - operand.mask12 < 0);
          _setFlag(Flags.v, ((ya ^ operand) & (ya ^ r) & 0x8000) != 0);
          _setFlag(Flags.c, r >= 0);
          a = r.mask8;
          y = r.shr8.mask8;
          _setNZ16(r.mask16);
        }
        break;
      case 0x5a:
        {
          final p = _dp();
          final hiAddr = _dpBase() + (p - _dpBase() + 1).mask8;
          final ya = a | y.shl8;
          final operand = read(p) | read(hiAddr).shl8;
          final r = (ya - operand).mask16;
          _setFlag(Flags.c, ya >= operand);
          _setNZ16(r);
        }
        break;

      // ---------------------------------------------------------- MUL/DIV
      case 0xcf:
        {
          final r = y * a;
          y = r.shr8.mask8;
          a = r.mask8;
          _setNZ(y);
        }
        break;
      case 0x9e:
        {
          final ya = a | y.shl8;
          if (x == 0) {
            a = 0xff;
            y = ya.mask8; // documented edge case: div by zero
            _setFlag(Flags.v, true);
            _setFlag(Flags.h, true);
          } else {
            _setFlag(Flags.h, y.mask4 <= x.mask4);
            final q = ya ~/ x;
            final rem = ya % x;
            _setFlag(Flags.v, q > 0xff);
            a = q.mask8;
            y = rem.mask8;
          }
          _setNZ(a);
        }
        break;

      // ---------------------------------------------------------- DAA/DAS
      case 0xdf:
        {
          if (psw.bit0 || a > 0x99) {
            a = (a + 0x60).mask8;
            _setFlag(Flags.c, true);
          }
          if (psw.bit3 || a.mask4 > 0x09) {
            a = (a + 0x06).mask8;
          }
          _setNZ(a);
        }
        break;
      case 0xbe:
        {
          if (!psw.bit0 || a > 0x99) {
            a = (a - 0x60).mask8;
            _setFlag(Flags.c, false);
          }
          if (!psw.bit3 || a.mask4 > 0x09) {
            a = (a - 0x06).mask8;
          }
          _setNZ(a);
        }
        break;

      // ---------------------------------------------------------- XCN
      case 0x9f:
        a = (a.shr4 | a.shl4).mask8;
        _setNZ(a);
        break;

      // ---------------------------------------------------------- flags
      case 0x60:
        _setFlag(Flags.c, false);
        break;
      case 0x80:
        _setFlag(Flags.c, true);
        break;
      case 0xed:
        _setFlag(Flags.c, _carry == 0);
        break;
      case 0x20:
        _setFlag(Flags.p, false);
        break;
      case 0x40:
        _setFlag(Flags.p, true);
        break;
      case 0xa0:
        _setFlag(Flags.i, true);
        break;
      case 0xc0:
        _setFlag(Flags.i, false);
        break;
      case 0xe0:
        _setFlag(Flags.v, false);
        _setFlag(Flags.h, false);
        break;

      // ---------------------------------------------------------- bit ops
      case 0x02:
      case 0x22:
      case 0x42:
      case 0x62:
      case 0x82:
      case 0xa2:
      case 0xc2:
      case 0xe2:
        {
          final bit = op.shr5;
          final p = _dp();
          write(p, read(p) | (1 << bit));
        }
        break;
      case 0x12:
      case 0x32:
      case 0x52:
      case 0x72:
      case 0x92:
      case 0xb2:
      case 0xd2:
      case 0xf2:
        {
          final bit = op.shr5;
          final p = _dp();
          write(p, read(p) & ~(1 << bit));
        }
        break;
      case 0x03:
      case 0x23:
      case 0x43:
      case 0x63:
      case 0x83:
      case 0xa3:
      case 0xc3:
      case 0xe3:
        {
          final bit = op.shr5;
          final p = _dp();
          _branch(read(p).bit(bit));
        }
        break;
      case 0x13:
      case 0x33:
      case 0x53:
      case 0x73:
      case 0x93:
      case 0xb3:
      case 0xd3:
      case 0xf3:
        {
          final bit = op.shr5;
          final p = _dp();
          _branch(!read(p).bit(bit));
        }
        break;
      case 0x0e: // TSET1
        {
          final p = _abs();
          final v = read(p);
          _setNZ((a - v).mask8);
          write(p, v | a);
        }
        break;
      case 0x4e: // TCLR1
        {
          final p = _abs();
          final v = read(p);
          _setNZ((a - v).mask8);
          write(p, v & ~a);
        }
        break;
      case 0xaa: // MOV1 C,m.b
        {
          final (addr, bit) = _memBit();
          _setFlag(Flags.c, read(addr).bit(bit));
        }
        break;
      case 0xca: // MOV1 m.b,C
        {
          final (addr, bit) = _memBit();
          final v = _carry != 0 ? read(addr) | (1 << bit) : read(addr) & ~(1 << bit);
          write(addr, v);
        }
        break;
      case 0x0a: // OR1 C,m.b
        {
          final (addr, bit) = _memBit();
          _setFlag(Flags.c, _carry != 0 || read(addr).bit(bit));
        }
        break;
      case 0x2a: // OR1 C,/m.b
        {
          final (addr, bit) = _memBit();
          _setFlag(Flags.c, _carry != 0 || !read(addr).bit(bit));
        }
        break;
      case 0x4a: // AND1 C,m.b
        {
          final (addr, bit) = _memBit();
          _setFlag(Flags.c, _carry != 0 && read(addr).bit(bit));
        }
        break;
      case 0x6a: // AND1 C,/m.b
        {
          final (addr, bit) = _memBit();
          _setFlag(Flags.c, _carry != 0 && !read(addr).bit(bit));
        }
        break;
      case 0x8a: // EOR1 C,m.b
        {
          final (addr, bit) = _memBit();
          _setFlag(Flags.c, (_carry != 0) != read(addr).bit(bit));
        }
        break;
      case 0xea: // NOT1 m.b
        {
          final (addr, bit) = _memBit();
          write(addr, read(addr) ^ (1 << bit));
        }
        break;

      // ---------------------------------------------------------- branches
      case 0x2f:
        _branch(true);
        break;
      case 0xf0:
        _branch(psw.bit1);
        break;
      case 0xd0:
        _branch(!psw.bit1);
        break;
      case 0xb0:
        _branch(psw.bit0);
        break;
      case 0x90:
        _branch(!psw.bit0);
        break;
      case 0x70:
        _branch(psw.bit6);
        break;
      case 0x50:
        _branch(!psw.bit6);
        break;
      case 0x30:
        _branch(psw.bit7);
        break;
      case 0x10:
        _branch(!psw.bit7);
        break;
      case 0x2e: // CBNE d,r
        {
          final p = _dp();
          final v = read(p);
          _branch(a != v);
        }
        break;
      case 0xde: // CBNE d+X,r
        {
          final p = _dpX();
          final v = read(p);
          _branch(a != v);
        }
        break;
      case 0x6e: // DBNZ d,r
        {
          final p = _dp();
          final v = (read(p) - 1).mask8;
          write(p, v);
          _branch(v != 0);
        }
        break;
      case 0xfe: // DBNZ Y,r
        y = (y - 1).mask8;
        _branch(y != 0);
        break;

      // ---------------------------------------------------------- jumps/calls
      case 0x5f:
        pc = _abs();
        break;
      case 0x1f:
        {
          final p = (_abs() + x).mask16;
          pc = read(p) | read((p + 1).mask16).shl8;
        }
        break;
      case 0x3f:
        {
          final target = _abs();
          _push8(pc.shr8);
          _push8(pc.mask8);
          pc = target;
          cycle += 3;
        }
        break;
      case 0x4f: // PCALL u
        {
          final u = _fetch8();
          _push8(pc.shr8);
          _push8(pc.mask8);
          pc = 0xff00 | u;
          cycle += 2;
        }
        break;
      case 0x6f: // RET
        {
          final lo = _pull8();
          final hi = _pull8();
          pc = lo | hi.shl8;
          cycle += 3;
        }
        break;
      case 0x7f: // RET1
        {
          psw = _pull8();
          final lo = _pull8();
          final hi = _pull8();
          pc = lo | hi.shl8;
          cycle += 3;
        }
        break;
      case 0x0f: // BRK
        {
          _push8(pc.shr8);
          _push8(pc.mask8);
          _push8(psw);
          _setFlag(Flags.b, true);
          _setFlag(Flags.i, false);
          pc = read(0xffde) | read(0xffdf).shl8;
          cycle += 6;
        }
        break;

      default:
        if (op.mask4 == 0x01) {
          // TCALL n: n = op>>4, vector at $FFDE - n*2
          final n = op.shr4;
          final vecAddr = 0xffde - n * 2;
          _push8(pc.shr8);
          _push8(pc.mask8);
          pc = read(vecAddr) | read(vecAddr.inc).shl8;
          cycle += 6;
        } else {
          return false;
        }
    }

    _tickTimers(cycle - startCycle + 2);
    return true;
  }
}
