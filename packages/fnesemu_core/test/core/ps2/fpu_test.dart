import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ps2/bus.dart';
import 'package:fnesemu_core/src/core/ps2/r5900/fpu.dart';
import 'package:fnesemu_core/src/core/ps2/r5900/r5900.dart';
import 'package:test/test.dart';

int _cop1(int fmt, {int ft = 0, int fs = 0, int fd = 0, int fn = 0}) =>
    17 << 26 | fmt << 21 | ft << 16 | fs << 11 | fd << 6 | fn;
int _s(int fn, {int ft = 2, int fs = 1, int fd = 3}) =>
    _cop1(16, ft: ft, fs: fs, fd: fd, fn: fn);

final _f = ByteData(4);
int _bits(double v) {
  _f.setFloat32(0, v);
  return _f.getUint32(0);
}

double _val(int bits) {
  _f.setUint32(0, bits);
  return _f.getFloat32(0);
}

/// runs one instruction with f1 = [a] and f2 = [b] (raw images)
R5900 _run(int ir, {int a = 0, int b = 0}) {
  final cpu = R5900(Ps2Bus());
  cpu.bus.write32(0x100000, ir);
  cpu.jumpTo(0x100000);
  cpu.fpr[1] = a;
  cpu.fpr[2] = b;
  expect(cpu.step(), isTrue);
  return cpu;
}

void main() {
  test('basic arithmetic', () {
    final one = _bits(1.5), two = _bits(2.25);
    expect(_val(_run(_s(0), a: one, b: two).fpr[3]), 3.75);
    expect(_val(_run(_s(1), a: one, b: two).fpr[3]), -0.75);
    expect(_val(_run(_s(2), a: one, b: two).fpr[3]), 3.375);
    expect(_val(_run(_s(3), a: two, b: one).fpr[3]), 1.5);
    expect(_val(_run(_s(4), b: _bits(16)).fpr[3]), 4.0);
  });

  test('results round toward zero', () {
    // 1 + 2^-24 is halfway between two floats and truncates down
    final cpu = _run(_s(0), a: _bits(1.0), b: _bits(5.960464477539063e-8));
    expect(cpu.fpr[3], _bits(1.0));
    // 1/3 truncated is below the nearest-rounded value
    final third = _run(_s(3), a: _bits(1.0), b: _bits(3.0)).fpr[3];
    expect(third, 0x3eaaaaaa);
  });

  test('overflow clamps to the largest magnitude and denormals flush', () {
    final big = 0x7f7fffff;
    final cpu = _run(_s(2), a: big, b: big);
    expect(cpu.fpr[3], 0x7fffffff);
    expect(cpu.fcr31 & (1 << 15), isNonZero);
    expect(cpu.fcr31 & (1 << 4), isNonZero);
    final small = _run(_s(2), a: 0x00800000, b: _bits(0.5));
    expect(small.fpr[3], 0);
    expect(small.fcr31 & (1 << 14), isNonZero);
  });

  test('exponent 255 is a normal number', () {
    final cpu = _run(_s(0), a: 0x7f800000, b: 0x7f800000);
    expect(cpu.fpr[3], 0x7fffffff);
  });

  test('division by zero', () {
    final cpu = _run(_s(3), a: _bits(1.0), b: 0);
    expect(cpu.fpr[3], 0x7fffffff);
    expect(cpu.fcr31 & (1 << 16), isNonZero);
    final neg = _run(_s(3), a: _bits(-1.0), b: 0);
    expect(neg.fpr[3], 0xffffffff);
    final zero = _run(_s(3), a: 0, b: 0);
    expect(zero.fcr31 & (1 << 17), isNonZero);
  });

  test('accumulator forms', () {
    final cpu = R5900(Ps2Bus());
    cpu.bus.write32(0x100000, _s(0x1a)); // MULA
    cpu.bus.write32(0x100004, _s(0x1c, fd: 4)); // MADD
    cpu.jumpTo(0x100000);
    cpu.fpr[1] = _bits(2.0);
    cpu.fpr[2] = _bits(3.0);
    cpu.step();
    expect(_val(cpu.facc), 6.0);
    cpu.step();
    expect(_val(cpu.fpr[4]), 12.0);
  });

  test('compare sets C and BC1T branches on it', () {
    final cpu = R5900(Ps2Bus());
    cpu.bus.write32(0x100000, _s(0x34, fd: 0)); // C.LT f1, f2
    cpu.bus.write32(0x100004, 17 << 26 | 8 << 21 | 1 << 16 | 2); // bc1t +2
    cpu.bus.write32(0x100008, 0);
    cpu.jumpTo(0x100000);
    cpu.fpr[1] = _bits(1.0);
    cpu.fpr[2] = _bits(2.0);
    cpu.step();
    expect(cpu.fcr31 & R5900Fpu.conditionBit, isNonZero);
    cpu.step();
    cpu.step();
    expect(cpu.pc, 0x100004 + 4 + 8);
  });

  test('conversions and register moves', () {
    final w = _run(_cop1(20, fs: 1, fd: 3, fn: 0x20), a: 0xfffffffd);
    expect(_val(w.fpr[3]), -3.0);
    final i = _run(_s(0x24, fs: 1, fd: 3), a: _bits(-2.75));
    expect(i.fpr[3], 0xfffffffe);
    final sat = _run(_s(0x24, fs: 1, fd: 3), a: _bits(3e10));
    expect(sat.fpr[3], 0x7fffffff);

    final cpu = R5900(Ps2Bus());
    cpu.bus.write32(0x100000, _cop1(4, ft: 5, fs: 4)); // mtc1 r5, f4
    cpu.bus.write32(0x100004, _cop1(0, ft: 6, fs: 4)); // mfc1 r6, f4
    cpu.jumpTo(0x100000);
    cpu.setReg(5, 0x80000001);
    cpu.step();
    cpu.step();
    expect(cpu.reg(6), -0x7fffffff);
  });

  test('LWC1 and SWC1', () {
    final cpu = R5900(Ps2Bus());
    cpu.bus.write32(0x100000, 49 << 26 | 1 << 21 | 7 << 16 | 0x200); // lwc1
    cpu.bus.write32(0x100004, 57 << 26 | 1 << 21 | 7 << 16 | 0x300); // swc1
    cpu.jumpTo(0x100000);
    cpu.setReg(1, 0x100000);
    cpu.bus.write32(0x100200, 0x3f800000);
    cpu.step();
    cpu.step();
    expect(cpu.fpr[7], 0x3f800000);
    expect(cpu.bus.read32(0x100300), 0x3f800000);
  });

  test('MIN, MAX, ABS, NEG, MOV', () {
    final a = _bits(-1.0), b = _bits(2.0);
    expect(_run(_s(0x28), a: a, b: b).fpr[3], b);
    expect(_run(_s(0x29), a: a, b: b).fpr[3], a);
    expect(_val(_run(_s(0x05), a: a).fpr[3]), 1.0);
    expect(_val(_run(_s(0x07), a: b).fpr[3]), -2.0);
    expect(_run(_s(0x06), a: b).fpr[3], b);
  });
}
