/// A minimal x86-64 encoder for the backend: 32-bit integer operations,
/// 64-bit pointer moves, and rel32 jumps to labels.
library;

import 'dart:typed_data';

/// General purpose registers by their encoding number.
abstract final class R {
  static const rax = 0, rcx = 1, rdx = 2, rbx = 3, rsp = 4, rbp = 5;
  static const rsi = 6, rdi = 7, r8 = 8, r9 = 9, r10 = 10, r11 = 11;
  static const r12 = 12, r13 = 13, r14 = 14, r15 = 15;
}

/// A memory operand `[base + index * scale + disp]`.
final class Mem {
  final int base;
  final int index; // -1 for none
  final int scale; // 1, 2, 4 or 8
  final int disp;
  const Mem(this.base, {this.index = -1, this.scale = 1, this.disp = 0});
}

/// The condition codes of jcc, setcc and cmovcc.
abstract final class Cc {
  static const b = 0x2, ae = 0x3, e = 0x4, ne = 0x5, be = 0x6, a = 0x7;
  static const s = 0x8, ns = 0x9, l = 0xc, ge = 0xd, le = 0xe, g = 0xf;
}

/// The /digit of the group-1 ALU instructions, also used to select the
/// `op r32, r/m32` opcode as `digit * 8 + 3`.
abstract final class Alu {
  static const add = 0, or = 1, and = 4, sub = 5, xor = 6, cmp = 7;
}

/// The /digit of the shift group.
abstract final class Shift {
  static const shl = 4, shr = 5, sar = 7;
}

final class Label {
  int offset = -1;
  final _uses = <int>[]; // offsets of rel32 fields
}

final class Assembler {
  var _b = Uint8List(4096);
  int _length = 0;

  int get offset => _length;
  Uint8List get bytes => Uint8List.sublistView(_b, 0, _length);

  void _grow() {
    final next = Uint8List(_b.length * 2);
    next.setRange(0, _length, _b);
    _b = next;
  }

  void u8(int v) {
    if (_length == _b.length) _grow();
    _b[_length++] = v;
  }

  void u32(int v) {
    if (_length + 4 > _b.length) _grow();
    for (int i = 0; i < 4; i++) {
      _b[_length++] = v >> (8 * i);
    }
  }

  void u64(int v) {
    if (_length + 8 > _b.length) _grow();
    for (int i = 0; i < 8; i++) {
      _b[_length++] = v >> (8 * i);
    }
  }

  // REX prefix; emitted when any bit is set or [force] (byte registers)
  void _rex(bool w, int reg, int index, int base, {bool force = false}) {
    final v = 0x40 |
        (w ? 8 : 0) |
        ((reg >> 3) & 1) << 2 |
        ((index >> 3) & 1) << 1 |
        ((base >> 3) & 1);
    if (v != 0x40 || force) u8(v);
  }

  void _modrmReg(int reg, int rm) => u8(0xc0 | (reg & 7) << 3 | (rm & 7));

  void _modrmMem(int reg, Mem m) {
    final base = m.base & 7;
    final needsSib = m.index >= 0 || base == R.rsp;
    final int mod;
    if (m.disp == 0 && base != R.rbp) {
      mod = 0;
    } else if (m.disp >= -128 && m.disp < 128) {
      mod = 1;
    } else {
      mod = 2;
    }
    if (needsSib) {
      u8(mod << 6 | (reg & 7) << 3 | 4);
      final ss = switch (m.scale) { 1 => 0, 2 => 1, 4 => 2, _ => 3 };
      final index = m.index < 0 ? 4 : (m.index & 7);
      u8(ss << 6 | index << 3 | base);
    } else {
      u8(mod << 6 | (reg & 7) << 3 | base);
    }
    if (mod == 1) u8(m.disp);
    if (mod == 2) u32(m.disp);
  }

  void _opMem(List<int> op, int reg, Mem m,
      {bool w = false, bool byteReg = false}) {
    _rex(w, reg, m.index < 0 ? 0 : m.index, m.base, force: byteReg && reg >= 4);
    for (final o in op) {
      u8(o);
    }
    _modrmMem(reg, m);
  }

  void _opReg(List<int> op, int reg, int rm, {bool w = false}) {
    _rex(w, reg, 0, rm);
    for (final o in op) {
      u8(o);
    }
    _modrmReg(reg, rm);
  }

  /// Uses only caller-saved XMM0/XMM1 and RAX/RCX at an IR operation.
  void floatBinary(int opcode, {required bool wide}) {
    u8(0x66);
    _opReg([0x0f, 0x6e], 0, R.rax, w: wide);
    u8(0x66);
    _opReg([0x0f, 0x6e], 1, R.rcx, w: wide);
    if (!wide) {
      for (final reg in [0, 1]) {
        u8(0xf3);
        _opReg([0x0f, 0x5a], reg, reg);
      }
    }
    u8(0xf2);
    _opReg([0x0f, opcode], 0, 1);
    if (!wide) {
      u8(0xf2);
      _opReg([0x0f, 0x5a], 0, 0);
    }
    u8(0x66);
    _opReg([0x0f, 0x7e], 0, R.rax, w: wide);
  }

  /// Converts the binary32 or binary64 bits in RAX to the other width,
  /// using XMM0; narrowing rounds by MXCSR, which hosts keep at nearest.
  void floatConvert({required bool fromWide}) {
    u8(0x66);
    _opReg([0x0f, 0x6e], 0, R.rax, w: fromWide);
    u8(fromWide ? 0xf2 : 0xf3); // cvtsd2ss or cvtss2sd
    _opReg([0x0f, 0x5a], 0, 0);
    u8(0x66);
    _opReg([0x0f, 0x7e], 0, R.rax, w: !fromWide);
  }

  /// Converts the binary32 or binary64 bits in RAX to a signed word in EAX,
  /// toward zero or by MXCSR rounding (nearest), using XMM0.
  void floatToInt({required bool wide, required bool truncate}) {
    u8(0x66);
    _opReg([0x0f, 0x6e], 0, R.rax, w: wide);
    if (!wide) {
      u8(0xf3);
      _opReg([0x0f, 0x5a], 0, 0);
    }
    u8(0xf2); // cvttsd2si or cvtsd2si
    _opReg([0x0f, truncate ? 0x2c : 0x2d], R.rax, 0);
  }

  // moves

  void movRM(int dst, Mem m, {bool w = false}) => _opMem([0x8b], dst, m, w: w);
  void movMR(Mem m, int src, {bool w = false}) => _opMem([0x89], src, m, w: w);
  void movRM64(int dst, Mem m) => _opMem([0x8b], dst, m, w: true);
  void movMI(Mem m, int imm) {
    _opMem([0xc7], 0, m);
    u32(imm);
  }

  void movRR(int dst, int src, {bool w = false}) =>
      _opReg([0x89], src, dst, w: w);
  void movRI(int dst, int imm) {
    _rex(false, 0, 0, dst);
    u8(0xb8 + (dst & 7));
    u32(imm);
  }

  void movsxdRR(int dst, int src) => _opReg([0x63], dst, src, w: true);

  void bswap(int reg, {bool w = false}) {
    _rex(w, 0, 0, reg);
    u8(0x0f);
    u8(0xc8 + (reg & 7));
  }

  void swap16(int reg) {
    u8(0x66);
    _opReg([0xc1], 1, reg);
    u8(8);
  }

  void movRI64(int dst, int imm) {
    _rex(true, 0, 0, dst);
    u8(0xb8 + (dst & 7));
    u64(imm);
  }

  void mov16MR(Mem m, int src) {
    u8(0x66);
    _opMem([0x89], src, m);
  }

  void mov8MR(Mem m, int src) => _opMem([0x88], src, m, byteReg: true);

  void movzx8RM(int dst, Mem m, {bool w = false}) =>
      _opMem([0x0f, 0xb6], dst, m, w: w);
  void movzx16RM(int dst, Mem m, {bool w = false}) =>
      _opMem([0x0f, 0xb7], dst, m, w: w);
  void movsx8RM(int dst, Mem m, {bool w = false}) =>
      _opMem([0x0f, 0xbe], dst, m, w: w);
  void movsx16RM(int dst, Mem m, {bool w = false}) =>
      _opMem([0x0f, 0xbf], dst, m, w: w);
  void movzx8RR(int dst, int src, {bool w = false}) {
    _rex(w, dst, 0, src, force: src >= 4);
    u8(0x0f);
    u8(0xb6);
    _modrmReg(dst, src);
  }

  void movzx16RR(int dst, int src, {bool w = false}) =>
      _opReg([0x0f, 0xb7], dst, src, w: w);
  void movsx8RR(int dst, int src, {bool w = false}) {
    _rex(w, dst, 0, src, force: src >= 4);
    u8(0x0f);
    u8(0xbe);
    _modrmReg(dst, src);
  }

  void movsx16RR(int dst, int src, {bool w = false}) =>
      _opReg([0x0f, 0xbf], dst, src, w: w);

  // arithmetic

  void aluRM(int alu, int dst, Mem m, {bool w = false}) =>
      _opMem([alu * 8 + 3], dst, m, w: w);
  void aluRR(int alu, int dst, int src, {bool w = false}) =>
      _opReg([alu * 8 + 3], dst, src, w: w);
  void aluRI(int alu, int dst, int imm, {bool w = false}) {
    _rex(w, 0, 0, dst);
    if (imm >= -128 && imm < 128) {
      u8(0x83);
      _modrmReg(alu, dst);
      u8(imm);
    } else {
      u8(0x81);
      _modrmReg(alu, dst);
      u32(imm);
    }
  }

  void aluMI(int alu, Mem m, int imm) {
    if (imm >= -128 && imm < 128) {
      _opMem([0x83], alu, m);
      u8(imm);
    } else {
      _opMem([0x81], alu, m);
      u32(imm);
    }
  }

  void testRR64(int a, int b) => _opReg([0x85], b, a, w: true);
  void shiftRCl(int shift, int dst, {bool w = false}) =>
      _opReg([0xd3], shift, dst, w: w);
  void shiftRI(int shift, int dst, int imm, {bool w = false}) {
    _opReg([0xc1], shift, dst, w: w);
    u8(imm);
  }

  void imulRI(int dst, int imm, {bool w = false}) {
    _opReg([imm >= -128 && imm < 128 ? 0x6b : 0x69], dst, dst, w: w);
    if (imm >= -128 && imm < 128) {
      u8(imm);
    } else {
      u32(imm);
    }
  }

  void imulRR(int dst, int src, {bool w = false}) =>
      _opReg([0x0f, 0xaf], dst, src, w: w);
  void imul1R(int src, {bool w = false}) => _opReg([0xf7], 5, src, w: w);
  void mul1R(int src, {bool w = false}) => _opReg([0xf7], 4, src, w: w);

  void imulRM(int dst, Mem m, {bool w = false}) =>
      _opMem([0x0f, 0xaf], dst, m, w: w);

  /// edx:eax = eax * [m], signed
  void imul1M(Mem m, {bool w = false}) => _opMem([0xf7], 5, m, w: w);

  /// edx:eax = eax * [m], unsigned
  void mul1M(Mem m, {bool w = false}) => _opMem([0xf7], 4, m, w: w);

  void setcc(int cc, int dst) {
    _rex(false, 0, 0, dst, force: dst >= 4);
    u8(0x0f);
    u8(0x90 + cc);
    _modrmReg(0, dst);
  }

  void cmovRR(int cc, int dst, int src, {bool w = false}) =>
      _opReg([0x0f, 0x40 + cc], dst, src, w: w);

  // control flow

  void bind(Label l) {
    l.offset = offset;
  }

  void _rel32(Label l) {
    l._uses.add(offset);
    u32(0);
  }

  void jmp(Label l) {
    u8(0xe9);
    _rel32(l);
  }

  void jcc(int cc, Label l) {
    u8(0x0f);
    u8(0x80 + cc);
    _rel32(l);
  }

  /// jumps to an absolute address within ±2GiB of the code at [base]
  void jmpAbs(int target, int base) {
    u8(0xe9);
    u32(target - (base + offset + 4));
  }

  void jmpR(int r) => _opReg([0xff], 4, r);
  void callR(int r) => _opReg([0xff], 2, r);
  void push(int r) {
    _rex(false, 0, 0, r);
    u8(0x50 + (r & 7));
  }

  void pop(int r) {
    _rex(false, 0, 0, r);
    u8(0x58 + (r & 7));
  }

  void ret() => u8(0xc3);

  /// resolves the rel32 fields of every label
  void link(Iterable<Label> labels) {
    for (final l in labels) {
      if (l.offset < 0 && l._uses.isNotEmpty) {
        throw StateError('unbound label');
      }
      for (final use in l._uses) {
        final rel = l.offset - (use + 4);
        for (int i = 0; i < 4; i++) {
          _b[use + i] = rel >> (8 * i);
        }
      }
    }
  }
}
