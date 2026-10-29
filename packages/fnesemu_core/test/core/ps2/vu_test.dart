import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ps2/vu.dart';
import 'package:test/test.dart';

const _x = 8, _y = 4, _z = 2, _w = 1, _xyzw = 15;
const _upperNop = 0x000002ff, _lowerNop = 0x8000033c;

final _f = ByteData(4);
int _bits(double v) {
  _f.setFloat32(0, v);
  return _f.getUint32(0);
}

double _val(int bits) {
  _f.setUint32(0, bits);
  return _f.getFloat32(0);
}

int _up(int op, int dest, int fd, int fs, int ft,
        {bool e = false, bool i = false}) =>
    (i ? 1 << 31 : 0) |
    (e ? 1 << 30 : 0) |
    (dest << 21) |
    (ft << 16) |
    (fs << 11) |
    (fd << 6) |
    op;

/// special upper op: [sub] is bits 10..6 and [col] the low two bits
int _upSpecial(int sub, int col, int dest, int fs, int ft, {bool e = false}) =>
    (e ? 1 << 30 : 0) |
    (dest << 21) |
    (ft << 16) |
    (fs << 11) |
    (sub << 6) |
    (0x3c + col);

int _lo(int op, {int dest = 0, int it = 0, int is_ = 0, int imm = 0}) =>
    (op << 25) | (dest << 21) | (it << 16) | (is_ << 11) | (imm & 0x7ff);

int _loSpecial(int sub, int col,
        {int dest = 0, int it = 0, int fs = 0, int fsf = 0, int ftf = 0}) =>
    0x80000000 |
    (dest << 21) |
    (fsf << 21) |
    (ftf << 23) |
    (it << 16) |
    (fs << 11) |
    (sub << 6) |
    (0x3c + col);

Vu _vu(List<(int, int)> program, {int index = 1}) {
  final vu = Vu(index);
  for (var p = 0; p < program.length; p++) {
    vu.micro[p * 2] = program[p].$1; // lower
    vu.micro[p * 2 + 1] = program[p].$2; // upper
  }
  return vu;
}

void _setVf(Vu vu, int reg, List<double> v) {
  for (var c = 0; c < 4; c++) {
    vu.vf[reg * 4 + c] = _bits(v[c]);
  }
}

List<double> _getVf(Vu vu, int reg) =>
    [for (var c = 0; c < 4; c++) _val(vu.vf[reg * 4 + c])];

const _end = (_lowerNop, _upperNop);
(int, int) get _endPair => (_lowerNop, _upperNop | (1 << 30));

void main() {
  test('NOP encodings do nothing', () {
    final vu = _vu([(_lowerNop, _upperNop), _endPair, _end]);
    vu.start(0);
    expect(vu.running, isFalse);
    expect(vu.pc, 3);
  });

  test('ADD, SUB, MUL work per lane', () {
    final vu = _vu([
      (_lowerNop, _up(0x28, _xyzw, 3, 1, 2)), // ADD vf3 = vf1 + vf2
      (_lowerNop, _up(0x2c, _xyzw, 4, 1, 2)), // SUB
      (_lowerNop, _up(0x2a, _xyzw, 5, 1, 2)), // MUL
      (_lowerNop, _upperNop | (1 << 30)),
      _end,
    ]);
    _setVf(vu, 1, [1, 2, 3, 4]);
    _setVf(vu, 2, [10, 20, 30, 40]);
    vu.start(0);
    expect(_getVf(vu, 3), [11, 22, 33, 44]);
    expect(_getVf(vu, 4), [-9, -18, -27, -36]);
    expect(_getVf(vu, 5), [10, 40, 90, 160]);
  });

  test('the destination mask limits the written lanes and VF0 is constant', () {
    final vu = _vu([
      (_lowerNop, _up(0x28, _x | _z, 3, 1, 2)),
      (_lowerNop, _up(0x28, _xyzw, 0, 1, 2)), // writes to VF0 are ignored
      _endPair,
      _end,
    ]);
    _setVf(vu, 1, [1, 2, 3, 4]);
    _setVf(vu, 2, [10, 20, 30, 40]);
    _setVf(vu, 3, [7, 7, 7, 7]);
    vu.start(0);
    expect(_getVf(vu, 3), [11, 7, 33, 7]);
    expect(_getVf(vu, 0), [0, 0, 0, 1]);
  });

  test('broadcast operands use one lane of ft', () {
    final vu = _vu([
      (_lowerNop, _up(0x18 + 1, _xyzw, 3, 1, 2)), // MULy
      (_lowerNop, _up(0x00 + 3, _xyzw, 4, 1, 2)), // ADDw
      _endPair,
      _end,
    ]);
    _setVf(vu, 1, [1, 2, 3, 4]);
    _setVf(vu, 2, [10, 20, 30, 40]);
    vu.start(0);
    expect(_getVf(vu, 3), [20, 40, 60, 80]);
    expect(_getVf(vu, 4), [41, 42, 43, 44]);
  });

  test('ADDA, MADD and MSUB use the accumulator', () {
    final vu = _vu([
      (_lowerNop, _upSpecial(0xa, 0, _xyzw, 1, 2)), // ADDA acc = vf1 + vf2
      (_lowerNop, _up(0x29, _xyzw, 3, 1, 2)), // MADD vf3 = acc + vf1 * vf2
      (_lowerNop, _up(0x2d, _xyzw, 4, 1, 2)), // MSUB vf4 = acc - vf1 * vf2
      _endPair,
      _end,
    ]);
    _setVf(vu, 1, [1, 2, 3, 4]);
    _setVf(vu, 2, [10, 20, 30, 40]);
    vu.start(0);
    expect(_getVf(vu, 3), [21, 62, 123, 204]);
    expect(_getVf(vu, 4), [1, -18, -57, -116]);
  });

  test('MAX and MINI pick lanes', () {
    final vu = _vu([
      (_lowerNop, _up(0x2b, _xyzw, 3, 1, 2)),
      (_lowerNop, _up(0x2f, _xyzw, 4, 1, 2)),
      _endPair,
      _end,
    ]);
    _setVf(vu, 1, [1, -5, 3, 40]);
    _setVf(vu, 2, [2, -6, 3, 4]);
    vu.start(0);
    expect(_getVf(vu, 3), [2, -5, 3, 40]);
    expect(_getVf(vu, 4), [1, -6, 3, 4]);
  });

  test('MAC flags report zero and sign per lane', () {
    final vu = _vu([
      (_lowerNop, _up(0x2c, _xyzw, 3, 1, 2)), // SUB
      _endPair,
      _end,
    ]);
    _setVf(vu, 1, [1, 2, 3, 4]);
    _setVf(vu, 2, [1, 5, 3, 1]);
    vu.start(0);
    // lane x and z are zero; lane y is negative
    expect(vu.mac & 0x000f, 8 | 2);
    expect(vu.mac & 0x00f0, 4 << 4);
    expect(vu.mac & 0xff00, 0);
    expect(vu.status & 3, 3);
    expect(vu.status & 0xc0, 0xc0, reason: 'sticky Z and S');
  });

  test('flag instructions see FMAC flags four cycles after the issue', () {
    final vu = _vu([
      (_lowerNop, _up(0x2c, _xyzw, 3, 1, 2)), // SUB: y is negative
      (_lo(0x1a, it: 4, is_: 2), _upperNop), // FMAND one cycle later
      (_lowerNop, _up(0x2b, _xyzw, 6, 1, 2)), // MAX sets no flags
      (_lowerNop, _upperNop),
      (_lo(0x1a, it: 5, is_: 2), _upperNop), // FMAND four cycles later
      _endPair,
      _end,
    ]);
    _setVf(vu, 1, [1, 2, 3, 4]);
    _setVf(vu, 2, [1, 5, 3, 1]);
    vu.vi[2] = 0xffff;
    vu.start(0);
    expect(vu.vi[4], 0);
    expect(vu.vi[5], 0x4a);
  });

  test('CLIP shifts its judgement into the clip flag four cycles later', () {
    final vu = _vu([
      (_lowerNop, _upSpecial(7, 3, _xyzw, 1, 2)), // CLIP vf1, vf2.w
      (_lo(0x1c, it: 3), _upperNop), // FCGET one cycle later
      (_lowerNop, _upperNop),
      (_lowerNop, _upperNop),
      (_lo(0x1c, it: 4), _upperNop), // FCGET four cycles later
      _endPair,
      _end,
    ]);
    _setVf(vu, 1, [2, -3, 0.5, 1]);
    _setVf(vu, 2, [0, 0, 0, 1]);
    vu.writeControl(18, 0x3);
    vu.start(0);
    expect(vu.vi[3], 0x3);
    // +x and -y in the new judgement, the old one shifted up
    expect(vu.vi[4], 0x3 << 6 | 0x1 | 0x8);
  });

  test('ITOF and FTOI convert with fixed point scaling', () {
    final vu = _vu([
      (_lowerNop, _upSpecial(4, 1, _xyzw, 1, 3)), // ITOF4 vf3 = vf1 / 16
      (_lowerNop, _upSpecial(5, 1, _xyzw, 2, 4)), // FTOI4 vf4 = vf2 * 16
      _endPair,
      _end,
    ]);
    vu.vf[4] = 32;
    vu.vf[5] = 1;
    vu.vf[6] = 0xfffffff0;
    vu.vf[7] = 0;
    _setVf(vu, 2, [1.5, -2.25, 0.5, 1e9]);
    vu.start(0);
    expect(_getVf(vu, 3).sublist(0, 3), [2, 1.0 / 16, -1]);
    expect(vu.vf[16], 24);
    expect(vu.vf[17], 0xffffffdc);
    expect(vu.vf[19], 0x7fffffff);
  });

  test('Q register: DIV then WAITQ and MULq', () {
    final vu = _vu([
      (_loSpecial(0xe, 0, fs: 1, it: 2, fsf: 0, ftf: 1), _upperNop), // DIV
      (_loSpecial(0xe, 3), _upperNop), // WAITQ
      (_lowerNop, _up(0x1c, _xyzw, 3, 1, 0)), // MULq vf3 = vf1 * q
      _endPair,
      _end,
    ]);
    _setVf(vu, 1, [6, 2, 3, 4]);
    _setVf(vu, 2, [0, 2, 0, 0]);
    vu.start(0);
    expect(_val(vu.q), 3);
    expect(_getVf(vu, 3), [18, 6, 9, 12]);
  });

  test('Q keeps its old value until the division finishes', () {
    final vu = _vu([
      (_loSpecial(0xe, 0, fs: 1, it: 2, fsf: 0, ftf: 1), _upperNop), // DIV
      (_lowerNop, _up(0x1c, _x, 3, 1, 0)), // MULq, 1 cycle later: old Q
      (_lowerNop, _upperNop),
      (_lowerNop, _upperNop),
      (_lowerNop, _upperNop),
      (_lowerNop, _upperNop),
      (_lowerNop, _upperNop),
      (_lowerNop, _up(0x1c, _x, 4, 1, 0)), // MULq, 7 cycles later: new Q
      _endPair,
      _end,
    ]);
    _setVf(vu, 1, [6, 2, 3, 4]);
    _setVf(vu, 2, [0, 2, 0, 0]);
    vu.writeControl(22, _bits(10));
    vu.start(0);
    expect(_val(vu.vf[12]), 60);
    expect(_val(vu.vf[16]), 18);
  });

  test('a pair waits for the FMAC result it reads', () {
    final vu = _vu([
      (_lowerNop, _up(0x28, _xyzw, 3, 1, 1)), // ADD vf3 = vf1 + vf1
      (_lowerNop, _up(0x28, _xyzw, 4, 3, 3)), // ADD vf4 = vf3 + vf3
      _endPair,
      _end,
    ]);
    _setVf(vu, 1, [1, 2, 3, 4]);
    vu.start(0);
    expect(_getVf(vu, 4), [4, 8, 12, 16]);
    // the second ADD waits three cycles for vf3
    expect(vu.cycles, 4 + 3);
  });

  test('division by zero clamps Q and sets the D flag', () {
    final vu = _vu([
      (_loSpecial(0xe, 0, fs: 1, it: 2, fsf: 0, ftf: 0), _upperNop),
      _endPair,
      _end,
    ]);
    _setVf(vu, 1, [1, 0, 0, 0]);
    _setVf(vu, 2, [0, 0, 0, 0]);
    vu.start(0);
    expect(vu.q, 0x7fffffff);
    expect(vu.status & 0x20, 0x20);
  });

  test('SQRT and RSQRT', () {
    final vu = _vu([
      (_loSpecial(0xe, 1, it: 1, ftf: 0), _upperNop), // SQRT q, vf1.x
      (_loSpecial(0xe, 3), _upperNop), // WAITQ
      (_lowerNop, _up(0x1c, _x, 3, 2, 0)), // MULq vf3.x = vf2.x * q
      _endPair,
      _end,
    ]);
    _setVf(vu, 1, [16, 0, 0, 0]);
    _setVf(vu, 2, [5, 0, 0, 0]);
    vu.start(0);
    expect(_val(vu.q), 4);
    expect(_val(vu.vf[12]), 20);
  });

  test('ERCPR sets P after its latency and MFP reads it', () {
    final vu = _vu([
      (_loSpecial(0x1e, 2, fs: 1, fsf: 3), _upperNop), // ERCPR P, vf1.w
      (_loSpecial(0x19, 0, dest: _x, it: 2), _upperNop), // MFP vf2.x: old P
      (_loSpecial(0x1e, 3), _upperNop), // WAITP
      (_loSpecial(0x19, 0, dest: _y, it: 2), _upperNop), // MFP vf2.y
      (_loSpecial(0x1c, 0, fs: 3), _upperNop), // ESADD P = |vf3|^2
      (_loSpecial(0x1e, 3), _upperNop), // WAITP
      (_loSpecial(0x19, 0, dest: _z, it: 2), _upperNop), // MFP vf2.z
      _endPair,
      _end,
    ]);
    _setVf(vu, 1, [0, 0, 0, 4]);
    _setVf(vu, 3, [1, 2, 3, 9]);
    vu.start(0);
    expect(_getVf(vu, 2).sublist(0, 3), [0, 0.25, 14]);
  });

  test('the I bit loads a float into I for MULi', () {
    final vu = _vu([
      (_bits(2.5), _upperNop | (1 << 31)), // I = 2.5
      (_lowerNop, _up(0x1e, _xyzw, 3, 1, 0)), // MULi
      _endPair,
      _end,
    ]);
    _setVf(vu, 1, [1, 2, 3, 4]);
    vu.start(0);
    expect(_val(vu.i), 2.5);
    expect(_getVf(vu, 3), [2.5, 5, 7.5, 10]);
  });

  test('OPMULA and OPMSUB form a cross product', () {
    final vu = _vu([
      (_lowerNop, _upSpecial(0xb, 2, 14, 1, 2)), // OPMULA
      (_lowerNop, _up(0x2e, 14, 3, 2, 1)), // OPMSUB vf3 = acc - vf2 x vf1
      _endPair,
      _end,
    ]);
    _setVf(vu, 1, [1, 0, 0, 0]);
    _setVf(vu, 2, [0, 1, 0, 0]);
    vu.start(0);
    // ACC = a x b = (0, 0, 1); OPMSUB subtracts b x a-style products of
    // the swapped operands, which are zero here
    expect(_getVf(vu, 3).sublist(0, 3), [0, 0, 1]);
    expect(_val(vu.acc[2]), 1);
  });

  test('CLIP sets the clip flag bits', () {
    final vu = _vu([
      (_lowerNop, _upSpecial(7, 3, 14, 1, 2)), // CLIP vf1.xyz against vf2.w
      _endPair,
      _end,
    ]);
    _setVf(vu, 1, [5, -5, 0.5, 0]);
    _setVf(vu, 2, [0, 0, 0, 2]);
    vu.start(0);
    expect(vu.clip & 0x3f, 1 | (2 << 2));
  });

  test('integer instructions and loops with a branch delay slot', () {
    // vi1 = 3; loop: vi2 += 5; vi1 -= 1; ibne vi1, vi0, loop
    final vu = _vu([
      (_lo(0x08, it: 1, is_: 0, imm: 3), _upperNop), // IADDIU vi1, vi0, 3
      (_lo(0x08, it: 2, is_: 2, imm: 5), _upperNop), // loop: IADDIU vi2, vi2, 5
      (_lo(0x09, it: 1, is_: 1, imm: 1), _upperNop), // ISUBIU vi1, vi1, 1
      (_lo(0x29, it: 0, is_: 1, imm: -3), _upperNop), // IBNE vi0, vi1 -> loop
      (_lo(0x08, it: 3, is_: 3, imm: 1), _upperNop), // delay slot: vi3 += 1
      _endPair,
      _end,
    ]);
    vu.start(0);
    expect(vu.vi[2], 15);
    expect(vu.vi[1], 0);
    expect(vu.vi[3], 3, reason: 'the delay slot runs every time');
  });

  test('the E bit lets one more pair execute', () {
    final vu = _vu([
      (_lo(0x08, it: 1, is_: 0, imm: 1), _upperNop | (1 << 30)),
      (_lo(0x08, it: 2, is_: 0, imm: 2), _upperNop),
      (_lo(0x08, it: 3, is_: 0, imm: 3), _upperNop),
    ]);
    vu.start(0);
    expect((vu.vi[1], vu.vi[2], vu.vi[3]), (1, 2, 0));
  });

  test('BAL and JR call and return', () {
    final vu = _vu([
      (_lo(0x21, it: 15, imm: 3), _upperNop), // BAL vi15, +3 -> pair 4
      (_lowerNop, _upperNop), // delay slot
      (_lo(0x08, it: 4, is_: 0, imm: 7), _upperNop), // after return
      _endPair,
      (_lo(0x08, it: 5, is_: 0, imm: 9), _upperNop), // subroutine
      (_lo(0x24, is_: 15), _upperNop), // JR vi15
      (_lowerNop, _upperNop), // delay slot
    ]);
    vu.start(0);
    expect(vu.vi[15], 2);
    expect(vu.vi[5], 9);
    expect(vu.vi[4], 7);
  });

  test('LQ, SQ, ILW, ISW and the post increment forms', () {
    final vu = _vu([
      (_lo(0x08, it: 1, is_: 0, imm: 4), _upperNop), // vi1 = 4
      (
        _lo(0x00, dest: _xyzw, it: 5, is_: 1, imm: 1),
        _upperNop
      ), // LQ vf5 <- [5]
      (_lo(0x01, dest: _x | _y, it: 1, is_: 5, imm: 10), _upperNop), // SQ [14]
      (
        _lo(0x04, dest: _y, it: 6, is_: 1, imm: 1),
        _upperNop
      ), // ILW vi6 <- [5].y
      (_lo(0x05, dest: _w, it: 6, is_: 1, imm: 2), _upperNop), // ISW [6].w
      (
        _loSpecial(0xd, 0, dest: _xyzw, it: 7, fs: 1),
        _upperNop
      ), // LQI vf7, (vi1++)
      (
        _loSpecial(0xd, 1, dest: _xyzw, it: 1, fs: 7),
        _upperNop
      ), // SQI vf7, (vi1++)
      _endPair,
      _end,
    ]);
    for (var c = 0; c < 4; c++) {
      vu.data[5 * 4 + c] = _bits(c + 1.0);
      vu.data[4 * 4 + c] = _bits(100.0 + c);
    }
    vu.start(0);
    expect(_getVf(vu, 5), [1, 2, 3, 4]);
    expect(_val(vu.data[14 * 4]), 1);
    expect(_val(vu.data[14 * 4 + 1]), 2);
    expect(vu.data[14 * 4 + 2], 0);
    expect(vu.vi[6], _bits(2.0) & 0xffff);
    expect(vu.data[6 * 4 + 3], vu.vi[6]);
    expect(_getVf(vu, 7), [100, 101, 102, 103]);
    expect(vu.vi[1], 6);
    expect(_val(vu.data[5 * 4]), 100, reason: 'SQI stored vf7 at the old vi1');
  });

  test('the upper instruction reads registers before the lower one writes', () {
    final vu = _vu([
      // LQ vf1 <- [0] and ADD vf3 = vf1 + vf2 in the same pair
      (
        _lo(0x00, dest: _xyzw, it: 1, is_: 0, imm: 0),
        _up(0x28, _xyzw, 3, 1, 2)
      ),
      _endPair,
      _end,
    ]);
    _setVf(vu, 1, [1, 1, 1, 1]);
    _setVf(vu, 2, [2, 2, 2, 2]);
    for (var c = 0; c < 4; c++) {
      vu.data[c] = _bits(50);
    }
    vu.start(0);
    expect(_getVf(vu, 3), [3, 3, 3, 3]);
    expect(_getVf(vu, 1), [50, 50, 50, 50]);
  });

  test('MOVE and MR32 copy and rotate lanes', () {
    final vu = _vu([
      (_loSpecial(0xc, 0, dest: _xyzw, it: 2, fs: 1), _upperNop), // MOVE
      (_loSpecial(0xc, 1, dest: _xyzw, it: 3, fs: 1), _upperNop), // MR32
      _endPair,
      _end,
    ]);
    _setVf(vu, 1, [1, 2, 3, 4]);
    vu.start(0);
    expect(_getVf(vu, 2), [1, 2, 3, 4]);
    expect(_getVf(vu, 3), [2, 3, 4, 1]);
  });

  test('MTIR, MFIR and the flag instructions', () {
    final vu = _vu([
      (_loSpecial(0xf, 0, it: 1, fs: 2, fsf: 1), _upperNop), // MTIR vi1 = vf2.y
      (
        _loSpecial(0xf, 1, dest: _xyzw, it: 4, fs: 1),
        _upperNop
      ), // MFIR vf4 = vi1
      (_lo(0x11) | 0x123, _upperNop), // FCSET 0x123
      (_lo(0x1c, it: 5), _upperNop), // FCGET vi5
      _endPair,
      _end,
    ]);
    _setVf(vu, 2, [0, 0, 0, 0]);
    vu.vf[9] = 1234;
    vu.start(0);
    expect(vu.vi[1], 1234);
    expect(vu.vf[16], 1234);
    expect(vu.clip, 0x123);
    expect(vu.vi[5], 0x123);
  });

  test('XGKICK, XTOP and XITOP use the VIF values', () {
    var kicked = -1;
    final vu = _vu([
      (_lo(0x08, it: 1, is_: 0, imm: 9), _upperNop),
      (_loSpecial(0x1b, 0, fs: 1), _upperNop), // XGKICK vi1
      (_loSpecial(0x1a, 0, it: 2), _upperNop), // XTOP vi2
      (_loSpecial(0x1a, 1, it: 3), _upperNop), // XITOP vi3
      _endPair,
      _end,
    ]);
    vu.onXgkick = (a) => kicked = a;
    vu.top = () => 0x40;
    vu.itop = () => 0x4005;
    vu.start(0);
    expect(kicked, 9);
    expect(vu.vi[2], 0x40);
    expect(vu.vi[3], 5);
  });

  test('R register random numbers stay in the 1.0 to 2.0 range', () {
    final vu = _vu([
      (_loSpecial(0x10, 2, fs: 1, fsf: 0), _upperNop), // RINIT r = vf1.x
      (_loSpecial(0x10, 0, dest: _x, it: 2), _upperNop), // RNEXT vf2.x
      (_loSpecial(0x10, 0, dest: _x, it: 3), _upperNop),
      _endPair,
      _end,
    ]);
    vu.vf[4] = 0x12345;
    vu.start(0);
    final a = _val(vu.vf[8]), b = _val(vu.vf[12]);
    expect(a, inInclusiveRange(1.0, 2.0));
    expect(b, inInclusiveRange(1.0, 2.0));
    expect(a, isNot(b));
  });

  test('macro integer instructions run on VU0', () {
    final vu = Vu(0)
      ..vi[1] = 5
      ..vi[2] = 7;
    // COP2 macro words: VIADD vi3, vi1, vi2 and VIADDI vi4, vi1, -2
    vu.macro(0x4a000000 | 2 << 16 | 1 << 11 | 3 << 6 | 0x30);
    vu.macro(0x4a000000 | 4 << 16 | 1 << 11 | (-2 & 31) << 6 | 0x32);
    vu.macro(0x4a000000 | 2 << 16 | 1 << 11 | 5 << 6 | 0x34); // VIAND
    expect(vu.vi[3], 12);
    expect(vu.vi[4], 3);
    expect(vu.vi[5], 5);
  });
}
