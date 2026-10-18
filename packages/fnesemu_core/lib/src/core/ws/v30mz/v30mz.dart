import '../../../util/int.dart';

/// Memory and I/O accesses needed by the V30MZ CPU, with 20-bit memory
/// addresses and 8-bit I/O ports
abstract interface class V30Bus {
  int read8(int addr);
  void write8(int addr, int data);
  int input8(int port);
  void output8(int port, int data);
}

/// V30MZ: an 80186 compatible CPU without the V30 extensions
class V30mz {
  final V30Bus bus;

  /// the SoC of the color console, which sets ZF on MUL
  final bool colorSoc;

  V30mz(this.bus, {this.colorSoc = false});

  // general registers: ax cx dx bx sp bp si di
  final r = List<int>.filled(8, 0);
  // segment registers: es cs ss ds
  final s = List<int>.filled(4, 0);
  int ip = 0;
  int flags = _flagsFixed;

  int cycles = 0;
  bool halted = false;

  /// the vector number of the pending maskable interrupt, -1 for none
  int irqVector = -1;

  static const es = 0, cs = 1, ss = 2, ds = 3;
  static const ax = 0, cx = 1, dx = 2, bx = 3, sp = 4, bp = 5, si = 6, di = 7;

  static const cf = 0x0001;
  static const pf = 0x0004;
  static const af = 0x0010;
  static const zf = 0x0040;
  static const sf = 0x0080;
  static const tf = 0x0100;
  static const iff = 0x0200;
  static const df = 0x0400;
  static const of = 0x0800;
  static const _flagsFixed = 0xf002;
  static const _flagsMask = 0x0fd5;

  // prefixes of the current instruction
  int _segOverride = -1;
  int _rep = 0; // 0: none, 0xf2: repne, 0xf3: rep

  // the decoded modrm byte
  int _mod = 0, _reg = 0, _rm = 0;
  int _eaSeg = 0, _eaOff = 0;

  void reset() {
    r.fillRange(0, 8, 0);
    s.fillRange(0, 4, 0);
    s[cs] = 0xffff;
    ip = 0;
    flags = _flagsFixed;
    halted = false;
    irqVector = -1;
  }

  // ----------------------------------------------------------------------
  // registers and flags

  int reg8(int i) => i < 4 ? r[i].mask8 : r[i - 4].shr8;
  void setReg8(int i, int v) {
    if (i < 4) {
      r[i] = r[i] & 0xff00 | v.mask8;
    } else {
      r[i - 4] = r[i - 4].mask8 | v.mask8.shl8;
    }
  }

  bool _flag(int f) => flags & f != 0;
  void _setFlag(int f, bool on) => flags = on ? flags | f : flags & ~f;

  static final _parity = List<bool>.generate(256, (v) {
    var c = 0;
    for (var i = 0; i < 8; i++) {
      c += v >> i & 1;
    }
    return c.isEven;
  });

  void _setSZP8(int v) {
    flags = flags & ~(sf | zf | pf) |
        (v & 0x80 != 0 ? sf : 0) |
        (v.mask8 == 0 ? zf : 0) |
        (_parity[v.mask8] ? pf : 0);
  }

  void _setSZP16(int v) {
    flags = flags & ~(sf | zf | pf) |
        (v & 0x8000 != 0 ? sf : 0) |
        (v.mask16 == 0 ? zf : 0) |
        (_parity[v.mask8] ? pf : 0);
  }

  void _setSZP(int v, bool word) => word ? _setSZP16(v) : _setSZP8(v);

  // ----------------------------------------------------------------------
  // memory

  int _linear(int seg, int off) => (s[seg].shl4 + off.mask16) & 0xfffff;

  int read8(int seg, int off) {
    cycles++;
    return bus.read8(_linear(seg, off));
  }

  int read16(int seg, int off) {
    cycles++;
    return bus.read8(_linear(seg, off)) | bus.read8(_linear(seg, off + 1)).shl8;
  }

  void write8(int seg, int off, int v) {
    cycles++;
    bus.write8(_linear(seg, off), v.mask8);
  }

  void write16(int seg, int off, int v) {
    cycles++;
    bus.write8(_linear(seg, off), v.mask8);
    bus.write8(_linear(seg, off + 1), v.shr8.mask8);
  }

  int fetch8() {
    final v = bus.read8(_linear(cs, ip));
    ip = ip.inc.mask16;
    return v;
  }

  int fetch16() {
    final v = fetch8();
    return v | fetch8().shl8;
  }

  int _fetchS8() => fetch8().rel8;

  void push(int v) {
    r[sp] = (r[sp] - 2).mask16;
    write16(ss, r[sp], v);
  }

  int pop() {
    final v = read16(ss, r[sp]);
    r[sp] = (r[sp] + 2).mask16;
    return v;
  }

  int _seg(int def) => _segOverride >= 0 ? _segOverride : def;

  // ----------------------------------------------------------------------
  // modrm

  void _modrm() {
    final b = fetch8();
    _mod = b.shr6;
    _reg = b.shr3.mask3;
    _rm = b.mask3;
    if (_mod == 3) {
      // instructions which need an address get these modes instead
      const bases = [bx, bx, bp, bp, si, di, bp, bx];
      const segs = [ds, ds, ss, ss, ds, ds, ss, ds];
      _eaOff = (r[bases[_rm]] + r[_rm]).mask16;
      _eaSeg = _seg(segs[_rm]);
      return;
    }

    var seg = ds;
    int off;
    switch (_rm) {
      case 0:
        off = r[bx] + r[si];
      case 1:
        off = r[bx] + r[di];
      case 2:
        off = r[bp] + r[si];
        seg = ss;
      case 3:
        off = r[bp] + r[di];
        seg = ss;
      case 4:
        off = r[si];
      case 5:
        off = r[di];
      case 6:
        if (_mod == 0) {
          off = fetch16();
        } else {
          off = r[bp];
          seg = ss;
        }
      default:
        off = r[bx];
    }
    if (_mod == 1) {
      off += _fetchS8();
    } else if (_mod == 2) {
      off += fetch16();
    }
    _eaOff = off.mask16;
    _eaSeg = _seg(seg);
  }

  int _getRM(bool word) => _mod == 3
      ? (word ? r[_rm] : reg8(_rm))
      : (word ? read16(_eaSeg, _eaOff) : read8(_eaSeg, _eaOff));

  void _putRM(bool word, int v) {
    if (_mod == 3) {
      word ? r[_rm] = v.mask16 : setReg8(_rm, v);
    } else {
      word ? write16(_eaSeg, _eaOff, v) : write8(_eaSeg, _eaOff, v);
    }
  }

  int _getReg(bool word) => word ? r[_reg] : reg8(_reg);
  void _putReg(bool word, int v) =>
      word ? r[_reg] = v.mask16 : setReg8(_reg, v);

  // ----------------------------------------------------------------------
  // alu

  int _add(int a, int b, int c, bool word) {
    final res = a + b + c;
    final sign = word ? 0x8000 : 0x80;
    final mask = word ? 0xffff : 0xff;
    _setSZP(res, word);
    flags = flags & ~(cf | af | of) |
        (res > mask ? cf : 0) |
        ((a ^ b ^ res) & 0x10 != 0 ? af : 0) |
        ((res ^ a) & (res ^ b) & sign != 0 ? of : 0);
    return res & mask;
  }

  int _sub(int a, int b, int c, bool word) {
    final res = a - b - c;
    final sign = word ? 0x8000 : 0x80;
    final mask = word ? 0xffff : 0xff;
    _setSZP(res & mask, word);
    flags = flags & ~(cf | af | of) |
        (res < 0 ? cf : 0) |
        ((a ^ b ^ res) & 0x10 != 0 ? af : 0) |
        ((a ^ b) & (a ^ res) & sign != 0 ? of : 0);
    return res & mask;
  }

  int _logic(int v, bool word) {
    _setSZP(v, word);
    flags &= ~(cf | of | af);
    return v;
  }

  int _alu(int op, int a, int b, bool word) => switch (op) {
        0 => _add(a, b, 0, word),
        1 => _logic(a | b, word),
        2 => _add(a, b, _flag(cf) ? 1 : 0, word),
        3 => _sub(a, b, _flag(cf) ? 1 : 0, word),
        4 => _logic(a & b, word),
        5 => _sub(a, b, 0, word),
        6 => _logic(a ^ b, word),
        _ => _sub(a, b, 0, word),
      };

  int _inc(int v, bool word) {
    final c = flags & cf;
    final res = _add(v, 1, 0, word);
    flags = flags & ~cf | c;
    return res;
  }

  int _dec(int v, bool word) {
    final c = flags & cf;
    final res = _sub(v, 1, 0, word);
    flags = flags & ~cf | c;
    return res;
  }

  int _shift(int op, int v, int count, bool word) {
    // the count is masked, but the flags are updated even without a shift
    count &= 0x1f;
    final bits = word ? 16 : 8;
    final mask = word ? 0xffff : 0xff;
    final sign = word ? 0x8000 : 0x80;
    cycles += count;
    if (op == 6) {
      // SAL with the reg field 6 clears the operand
      v = 0;
      count = 0;
    }
    for (var i = 0; i < count; i++) {
      final c = flags & cf != 0 ? 1 : 0;
      switch (op) {
        case 0: // rol
          final out = v & sign != 0 ? 1 : 0;
          v = (v << 1 | out) & mask;
          _setFlag(cf, out != 0);
        case 1: // ror
          final out = v & 1;
          v = v >> 1 | out << (bits - 1);
          _setFlag(cf, out != 0);
        case 2: // rcl
          _setFlag(cf, v & sign != 0);
          v = (v << 1 | c) & mask;
        case 3: // rcr
          _setFlag(cf, v & 1 != 0);
          v = v >> 1 | c << (bits - 1);
        case 4: // shl
          _setFlag(cf, v & sign != 0);
          v = (v << 1) & mask;
        case 5: // shr
          _setFlag(cf, v & 1 != 0);
          v >>= 1;
        default: // sar
          _setFlag(cf, v & 1 != 0);
          v = v >> 1 | v & sign;
      }
    }
    if (op.isEven) {
      _setFlag(of, (v & sign != 0) != _flag(cf));
    } else {
      _setFlag(of, (v ^ v << 1) & sign != 0);
    }
    if (op >= 4) {
      _setSZP(v, word);
      flags &= ~af;
    }
    return v;
  }

  // ----------------------------------------------------------------------
  // control

  /// executes an interrupt through the vector table at 0000:0000
  void interrupt(int vector) {
    push(flags);
    flags &= ~(iff | tf);
    push(s[cs]);
    push(ip);
    ip = _readVector(vector * 4);
    s[cs] = _readVector(vector * 4 + 2);
    cycles += 10;
  }

  int _readVector(int addr) => bus.read8(addr) | bus.read8(addr + 1).shl8;

  bool _cond(int c) {
    final res = switch (c >> 1) {
      0 => _flag(of),
      1 => _flag(cf),
      2 => _flag(zf),
      3 => _flag(cf) || _flag(zf),
      4 => _flag(sf),
      5 => _flag(pf),
      6 => _flag(sf) != _flag(of),
      _ => _flag(zf) || _flag(sf) != _flag(of),
    };
    return c.isEven ? res : !res;
  }

  void _jumpRel(int rel) {
    ip = (ip + rel).mask16;
    cycles += 3;
  }

  /// executes an instruction, or accepts an interrupt.
  /// returns false on an undefined opcode
  bool exec() {
    if (irqVector >= 0) {
      halted = false;
      if (flags & iff != 0) {
        interrupt(irqVector);
        return true;
      }
    }
    if (halted) {
      cycles += 4;
      return true;
    }

    _segOverride = -1;
    _rep = 0;
    if (flags & tf != 0) {
      // single step: the trap is taken after the instruction
      final ok = _execPrefixed();
      interrupt(1);
      return ok;
    }
    return _execPrefixed();
  }

  bool _execPrefixed() {
    var op = fetch8();
    while (true) {
      switch (op) {
        case 0x26:
          _segOverride = es;
        case 0x2e:
          _segOverride = cs;
        case 0x36:
          _segOverride = ss;
        case 0x3e:
          _segOverride = ds;
        case 0xf0: // lock
          break;
        case 0xf2:
        case 0xf3:
          _rep = op;
        default:
          cycles++;
          return _exec(op);
      }
      cycles++;
      op = fetch8();
    }
  }

  bool _exec(int op) {
    if (op < 0x40 && op & 7 < 6) {
      final aluOp = op >> 3;
      final word = op.bit0;
      switch (op & 7) {
        case 0:
        case 1:
          _modrm();
          final res = _alu(aluOp, _getRM(word), _getReg(word), word);
          if (aluOp != 7) _putRM(word, res);
        case 2:
        case 3:
          _modrm();
          final res = _alu(aluOp, _getReg(word), _getRM(word), word);
          if (aluOp != 7) _putReg(word, res);
        case 4:
          final res = _alu(aluOp, reg8(0), fetch8(), false);
          if (aluOp != 7) setReg8(0, res);
        default:
          final res = _alu(aluOp, r[ax], fetch16(), true);
          if (aluOp != 7) r[ax] = res;
      }
      return true;
    }

    switch (op) {
      case 0x06:
      case 0x0e:
      case 0x16:
      case 0x1e:
        push(s[op >> 3]);
      case 0x07:
      case 0x17:
      case 0x1f:
        s[op >> 3] = pop();
      case 0x0f: // undefined opcodes are 1 byte nops
      case >= 0x63 && <= 0x67:
      case 0xf1:
        break;
      case 0x27: // daa
        _daa(false);
      case 0x2f: // das
        _daa(true);
      case 0x37: // aaa
        _aaa(false);
      case 0x3f: // aas
        _aaa(true);
      case >= 0x40 && <= 0x47:
        r[op & 7] = _inc(r[op & 7], true);
      case >= 0x48 && <= 0x4f:
        r[op & 7] = _dec(r[op & 7], true);
      case >= 0x50 && <= 0x57:
        push(op == 0x54 ? (r[sp] - 2).mask16 : r[op & 7]);
      case >= 0x58 && <= 0x5f:
        r[op & 7] = pop();
      case 0x60: // pusha
        final t = r[sp];
        for (var i = 0; i < 8; i++) {
          push(i == sp ? t : r[i]);
        }
      case 0x61: // popa
        for (var i = 7; i >= 0; i--) {
          final v = pop();
          if (i != sp) r[i] = v;
        }
      case 0x62: // bound
        _modrm();
        final lo = read16(_eaSeg, _eaOff).rel16;
        final hi = read16(_eaSeg, _eaOff + 2).rel16;
        final v = r[_reg].rel16;
        if (v < lo || v > hi) interrupt(5);
      case 0x68:
        push(fetch16());
      case 0x6a:
        push(_fetchS8().mask16);
      case 0x69:
      case 0x6b:
        _modrm();
        final a = _getRM(true).rel16;
        final b = op == 0x69 ? fetch16().rel16 : _fetchS8();
        final res = a * b;
        r[_reg] = res.mask16;
        _setMulFlags(res != res.mask16.rel16, true);
        cycles += 3;
      case 0x6c:
      case 0x6d:
      case 0x6e:
      case 0x6f:
        _string(op);
      case >= 0x70 && <= 0x7f:
        final rel = _fetchS8();
        if (_cond(op & 15)) _jumpRel(rel);
      case 0x80:
      case 0x81:
      case 0x82:
      case 0x83:
        final word = op.bit0;
        _modrm();
        final a = _getRM(word);
        final b = op == 0x81
            ? fetch16()
            : op == 0x83
                ? _fetchS8().mask16
                : fetch8();
        final res = _alu(_reg, a, b, word);
        if (_reg != 7) _putRM(word, res);
      case 0x84:
      case 0x85:
        final word = op.bit0;
        _modrm();
        _logic(_getRM(word) & _getReg(word), word);
      case 0x86:
      case 0x87:
        final word = op.bit0;
        _modrm();
        final t = _getRM(word);
        _putRM(word, _getReg(word));
        _putReg(word, t);
      case 0x88:
      case 0x89:
        final word = op.bit0;
        _modrm();
        _putRM(word, _getReg(word));
      case 0x8a:
      case 0x8b:
        final word = op.bit0;
        _modrm();
        _putReg(word, _getRM(word));
      case 0x8c:
        _modrm();
        _putRM(true, s[_reg.mask2]);
      case 0x8d: // lea
        _modrm();
        r[_reg] = _eaOff;
      case 0x8e:
        _modrm();
        s[_reg.mask2] = _getRM(true);
      case 0x8f:
        _modrm();
        _putRM(true, pop());
      case 0x90:
        break;
      case >= 0x91 && <= 0x97:
        final t = r[ax];
        r[ax] = r[op & 7];
        r[op & 7] = t;
      case 0x98: // cbw
        r[ax] = reg8(0).rel8.mask16;
      case 0x99: // cwd
        r[dx] = r[ax].bit15 ? 0xffff : 0;
      case 0x9a: // call far
        final off = fetch16();
        final seg = fetch16();
        push(s[cs]);
        push(ip);
        ip = off;
        s[cs] = seg;
        cycles += 5;
      case 0x9b: // wait
        break;
      case 0x9c:
        push(flags);
      case 0x9d:
        flags = pop() & _flagsMask | _flagsFixed;
      case 0x9e: // sahf
        flags = flags & 0xff00 | reg8(4) & 0xd5 | 2;
      case 0x9f: // lahf
        setReg8(4, flags.mask8);
      case 0xa0:
        setReg8(0, read8(_seg(ds), fetch16()));
      case 0xa1:
        r[ax] = read16(_seg(ds), fetch16());
      case 0xa2:
        write8(_seg(ds), fetch16(), reg8(0));
      case 0xa3:
        write16(_seg(ds), fetch16(), r[ax]);
      case >= 0xa4 && <= 0xa7:
      case >= 0xaa && <= 0xaf:
        _string(op);
      case 0xa8:
        _logic(reg8(0) & fetch8(), false);
      case 0xa9:
        _logic(r[ax] & fetch16(), true);
      case >= 0xb0 && <= 0xb7:
        setReg8(op & 7, fetch8());
      case >= 0xb8 && <= 0xbf:
        r[op & 7] = fetch16();
      case 0xc0:
      case 0xc1:
      case 0xd0:
      case 0xd1:
      case 0xd2:
      case 0xd3:
        final word = op.bit0;
        _modrm();
        final v = _getRM(word);
        final count = op < 0xd0
            ? fetch8()
            : op < 0xd2
                ? 1
                : reg8(1);
        _putRM(word, _shift(_reg, v, count, word));
      case 0xc2:
        final n = fetch16();
        ip = pop();
        r[sp] = (r[sp] + n).mask16;
        cycles += 5;
      case 0xc3:
        ip = pop();
        cycles += 5;
      case 0xc4:
      case 0xc5:
        _modrm();
        r[_reg] = read16(_eaSeg, _eaOff);
        s[op == 0xc4 ? es : ds] = read16(_eaSeg, _eaOff + 2);
      case 0xc6:
        _modrm();
        _putRM(false, fetch8());
      case 0xc7:
        _modrm();
        _putRM(true, fetch16());
      case 0xc8: // enter
        final size = fetch16();
        final level = fetch8().mask5;
        push(r[bp]);
        final frame = r[sp];
        for (var i = 1; i < level; i++) {
          r[bp] = (r[bp] - 2).mask16;
          push(read16(ss, r[bp]));
        }
        if (level > 0) push(frame);
        r[bp] = frame;
        r[sp] = (r[sp] - size).mask16;
        cycles += 7;
      case 0xc9: // leave
        r[sp] = r[bp];
        r[bp] = pop();
      case 0xca:
        final n = fetch16();
        ip = pop();
        s[cs] = pop();
        r[sp] = (r[sp] + n).mask16;
        cycles += 8;
      case 0xcb:
        ip = pop();
        s[cs] = pop();
        cycles += 8;
      case 0xcc:
        interrupt(3);
      case 0xcd:
        interrupt(fetch8());
      case 0xce:
        if (_flag(of)) interrupt(4);
      case 0xcf: // iret
        ip = pop();
        s[cs] = pop();
        flags = pop() & _flagsMask | _flagsFixed;
        cycles += 9;
      case 0xd4: // aam
        final base = fetch8();
        if (base == 0) {
          _divideError(reg8(0) & 0xc0 == 0);
          return true;
        }
        final al = reg8(0);
        r[ax] = (al ~/ base).shl8 | al % base;
        _setSZP8(r[ax].mask8);
        flags &= ~(af | cf | of);
        cycles += 16;
      case 0xd5: // aad
        final base = fetch8();
        r[ax] = _add((reg8(4) * base).mask8, reg8(0), 0, false);
        cycles += 5;
      case 0xd6: // salc
        setReg8(0, _flag(cf) ? 0xff : 0);
      case 0xd7: // xlat
        setReg8(0, read8(_seg(ds), r[bx] + reg8(0)));
      case >= 0xd8 && <= 0xdf: // no coprocessor: 2 byte nops
        fetch8();
      case 0xe0:
      case 0xe1:
      case 0xe2:
        final rel = _fetchS8();
        r[cx] = (r[cx] - 1).mask16;
        final z = _flag(zf);
        if (r[cx] != 0 && (op == 0xe2 || (op == 0xe1) == z)) _jumpRel(rel);
      case 0xe3:
        final rel = _fetchS8();
        if (r[cx] == 0) _jumpRel(rel);
      case 0xe4:
        setReg8(0, _in8(fetch8()));
      case 0xe5:
        final port = fetch8();
        r[ax] = _in8(port) | _in8(port + 1).shl8;
      case 0xe6:
        _out8(fetch8(), reg8(0));
      case 0xe7:
        final port = fetch8();
        _out8(port, r[ax].mask8);
        _out8(port + 1, r[ax].shr8);
      case 0xe8:
        final rel = fetch16();
        push(ip);
        ip = (ip + rel).mask16;
        cycles += 4;
      case 0xe9:
        _jumpRel(fetch16());
      case 0xea:
        final off = fetch16();
        s[cs] = fetch16();
        ip = off;
        cycles += 6;
      case 0xeb:
        _jumpRel(_fetchS8());
      case 0xec:
        setReg8(0, _in8(r[dx]));
      case 0xed:
        r[ax] = _in8(r[dx]) | _in8(r[dx] + 1).shl8;
      case 0xee:
        _out8(r[dx], reg8(0));
      case 0xef:
        _out8(r[dx], r[ax].mask8);
        _out8(r[dx] + 1, r[ax].shr8);
      case 0xf4:
        halted = true;
      case 0xf5:
        flags ^= cf;
      case 0xf6:
      case 0xf7:
        return _group3(op.bit0);
      case 0xf8:
        flags &= ~cf;
      case 0xf9:
        flags |= cf;
      case 0xfa:
        flags &= ~iff;
      case 0xfb:
        flags |= iff;
      case 0xfc:
        flags &= ~df;
      case 0xfd:
        flags |= df;
      case 0xfe:
        _modrm();
        final v = _reg < 2 ? _getRM(false) : 0;
        if (_reg == 0) {
          _putRM(false, _inc(v, false));
        } else if (_reg == 1) {
          _putRM(false, _dec(v, false));
        } else {
          // the other operations work as the 0xff variants
          return _group5(decoded: true);
        }
      case 0xff:
        return _group5();
      default:
        return false;
    }
    return true;
  }

  int _in8(int port) {
    cycles++;
    return bus.input8(port.mask8);
  }

  void _out8(int port, int v) {
    cycles++;
    bus.output8(port.mask8, v);
  }

  // CF and OF of the last multiplication, which division keeps
  bool _mulOverflow = false;

  void _setMulFlags(bool overflow, bool zero) {
    _mulOverflow = overflow;
    flags = flags & ~(af | pf | sf | zf | cf | of) |
        (overflow ? cf | of : 0) |
        (zero ? zf : 0);
  }

  // division flags: AF, PF and SF are cleared
  void _setDivFlags({required bool zero, required bool keepOverflow}) {
    flags = flags & ~(af | pf | sf | zf | cf | of) |
        (keepOverflow && _mulOverflow ? cf | of : 0) |
        (zero ? zf : 0);
  }

  void _divideError(bool zero) {
    _setDivFlags(zero: zero, keepOverflow: true);
    interrupt(0);
  }

  bool _group3(bool word) {
    _modrm();
    final v = _getRM(word);
    switch (_reg) {
      case 0:
        _logic(v & (word ? fetch16() : fetch8()), word);
      case 1: // changes nothing
        word ? fetch16() : fetch8();
      case 2:
        _putRM(word, ~v & (word ? 0xffff : 0xff));
      case 3:
        final res = _sub(0, v, 0, word);
        _putRM(word, res);
      case 4: // mul
        if (word) {
          final res = r[ax] * v;
          r[ax] = res.mask16;
          r[dx] = res.shr16.mask16;
          _setMulFlags(r[dx] != 0, colorSoc);
        } else {
          r[ax] = reg8(0) * v;
          _setMulFlags(r[ax].shr8 != 0, colorSoc);
        }
        cycles += 3;
      case 5: // imul
        if (word) {
          final res = r[ax].rel16 * v.rel16;
          r[ax] = res.mask16;
          r[dx] = (res >> 16).mask16;
          _setMulFlags(res != res.mask16.rel16, true);
        } else {
          final res = reg8(0).rel8 * v.rel8;
          r[ax] = res.mask16;
          _setMulFlags(res != res.mask8.rel8, true);
        }
        cycles += 3;
      case 6: // div
        cycles += 15;
        if (word) {
          final n = r[dx].shl16 | r[ax];
          if (v == 0 || n ~/ v > 0xffff) {
            final d = (0x10000 - v).mask16;
            _setDivFlags(
                zero: v == 0
                    ? n & 0x3fffc000 == 0
                    : (n + (d << 14)) & 0xffffc000 == 0 ||
                        (n + ((d * 3) << 14)) & 0xffffc000 == 0,
                keepOverflow: false);
            interrupt(0);
            return true;
          }
          final q = n ~/ v;
          r[dx] = n % v;
          r[ax] = q;
          _setDivFlags(zero: r[dx] == 0 && q.bit0, keepOverflow: false);
        } else {
          final n = r[ax];
          if (v == 0 || n ~/ v > 0xff) {
            final d = (0x100 - v).mask8;
            _divideError(v == 0
                ? n & 0x3fc0 == 0
                : (n + (d << 6)) & 0xffc0 == 0 ||
                    (n + ((d * 3) << 6)) & 0xffc0 == 0);
            return true;
          }
          final q = n ~/ v;
          r[ax] = (n % v).shl8 | q;
          _setDivFlags(zero: n % v == 0 && q.bit0, keepOverflow: true);
        }
      default: // idiv: the quotients -128 and -32768 raise the exception
        cycles += 18;
        if (word) {
          final n = (r[dx].shl16 | r[ax]).rel32;
          if (v == 0 && n == -0x80000000) {
            r[dx] = 0;
            r[ax] = 0x8001;
            _setDivFlags(zero: true, keepOverflow: false);
            return true;
          }
          final d = v.rel16;
          if (d == 0 || n ~/ d > 0x7fff || n ~/ d < -0x7fff) {
            _setDivFlags(zero: false, keepOverflow: false);
            interrupt(0);
            return true;
          }
          final q = n ~/ d;
          r[dx] = n.remainder(d).mask16;
          r[ax] = q.mask16;
          _setDivFlags(zero: r[dx] == 0 && q.isOdd, keepOverflow: false);
        } else {
          final n = r[ax].rel16;
          if (v == 0 && n == -0x8000) {
            r[ax] = 0x0081;
            _setSZP8(0x81);
            flags &= ~(af | cf | of);
            return true;
          }
          final d = v.rel8;
          if (d == 0 || n ~/ d > 0x7f || n ~/ d < -0x7f) {
            _divideError(false);
            return true;
          }
          final q = n ~/ d;
          r[ax] = n.remainder(d).mask8.shl8 | q.mask8;
          _setSZP8(q.mask8);
          flags &= ~(af | cf | of);
        }
    }
    return true;
  }

  bool _group5({bool decoded = false}) {
    if (!decoded) _modrm();
    switch (_reg) {
      case 0:
        _putRM(true, _inc(_getRM(true), true));
      case 1:
        _putRM(true, _dec(_getRM(true), true));
      case 2:
        final target = _getRM(true);
        push(ip);
        ip = target;
        cycles += 4;
      case 3:
        // the return address is pushed before the target is read
        push(s[cs]);
        push(ip);
        final off = read16(_eaSeg, _eaOff);
        final seg = read16(_eaSeg, _eaOff + 2);
        ip = off;
        s[cs] = seg;
        cycles += 8;
      case 4:
        ip = _getRM(true);
        cycles += 3;
      case 5:
        final off = read16(_eaSeg, _eaOff);
        s[cs] = read16(_eaSeg, _eaOff + 2);
        ip = off;
        cycles += 6;
      case 6:
        push(_getRM(true));
      default:
        break;
    }
    return true;
  }

  // string instructions, repeated with the rep prefixes
  void _string(int op) {
    final word = op.bit0;
    final step = (_flag(df) ? -1 : 1) * (word ? 2 : 1);
    final compare = op == 0xa6 || op == 0xa7 || op == 0xae || op == 0xaf;
    while (true) {
      if (_rep != 0) {
        if (r[cx] == 0) return;
      }
      switch (op & 0xfe) {
        case 0x6c: // ins
          final v = word ? _in8(r[dx]) | _in8(r[dx] + 1).shl8 : _in8(r[dx]);
          word ? write16(es, r[di], v) : write8(es, r[di], v);
          r[di] = (r[di] + step).mask16;
        case 0x6e: // outs
          final v = word ? read16(_seg(ds), r[si]) : read8(_seg(ds), r[si]);
          _out8(r[dx], v.mask8);
          if (word) _out8(r[dx] + 1, v.shr8);
          r[si] = (r[si] + step).mask16;
        case 0xa4: // movs
          final v = word ? read16(_seg(ds), r[si]) : read8(_seg(ds), r[si]);
          word ? write16(es, r[di], v) : write8(es, r[di], v);
          r[si] = (r[si] + step).mask16;
          r[di] = (r[di] + step).mask16;
        case 0xa6: // cmps
          final a = word ? read16(_seg(ds), r[si]) : read8(_seg(ds), r[si]);
          final b = word ? read16(es, r[di]) : read8(es, r[di]);
          _sub(a, b, 0, word);
          r[si] = (r[si] + step).mask16;
          r[di] = (r[di] + step).mask16;
        case 0xaa: // stos
          word ? write16(es, r[di], r[ax]) : write8(es, r[di], reg8(0));
          r[di] = (r[di] + step).mask16;
        case 0xac: // lods
          if (word) {
            r[ax] = read16(_seg(ds), r[si]);
          } else {
            setReg8(0, read8(_seg(ds), r[si]));
          }
          r[si] = (r[si] + step).mask16;
        default: // scas
          final b = word ? read16(es, r[di]) : read8(es, r[di]);
          _sub(word ? r[ax] : reg8(0), b, 0, word);
          r[di] = (r[di] + step).mask16;
      }
      cycles++;
      if (_rep == 0) return;
      r[cx] = (r[cx] - 1).mask16;
      if (compare && (_rep == 0xf3) != _flag(zf)) return;
    }
  }

  // the flags are those of the addition of the adjustment, except that
  // AF and CF are never cleared
  void _daa(bool sub) {
    final al = reg8(0);
    final lowAdjust = al.mask4 > 9 || _flag(af);
    final highAdjust = al > 0x99 || _flag(cf);
    final adjust = (lowAdjust ? 6 : 0) + (highAdjust ? 0x60 : 0);
    setReg8(0, sub ? _sub(al, adjust, 0, false) : _add(al, adjust, 0, false));
    flags = flags & ~(af | cf) | (lowAdjust ? af : 0) | (highAdjust ? cf : 0);
  }

  void _aaa(bool sub) {
    final adjust = reg8(0).mask4 > 9 || _flag(af);
    if (adjust) {
      setReg8(0, sub ? reg8(0) - 6 : reg8(0) + 6);
      setReg8(4, sub ? reg8(4) - 1 : reg8(4) + 1);
    }
    setReg8(0, reg8(0).mask4);
    flags =
        flags & ~(af | cf | zf | sf | of) | pf | (adjust ? af | cf | zf : sf);
  }

  String dump() {
    const names = ["ax", "cx", "dx", "bx", "sp", "bp", "si", "di"];
    const segs = ["es", "cs", "ss", "ds"];
    const f = "ODITSZ-A-P-C";
    final bits = [11, 10, 9, 8, 7, 6, -1, 4, -1, 2, -1, 0];
    final flagText = List.generate(f.length, (i) {
      if (bits[i] < 0) return "-";
      return flags & (1 << bits[i]) != 0 ? f[i] : f[i].toLowerCase();
    }).join();
    return "${List.generate(8, (i) => "${names[i]}:${r[i].x4}").join(" ")}\n"
        "${List.generate(4, (i) => "${segs[i]}:${s[i].x4}").join(" ")} "
        "ip:${ip.x4} $flagText${halted ? " H" : ""}";
  }
}
