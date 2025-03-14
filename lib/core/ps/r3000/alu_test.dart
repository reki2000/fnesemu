import 'package:fnesemu/util/int.dart';
import 'package:test/test.dart';

main() {
  test('mult-sign', () {
    mult(1, -1);
    expect(lo, 0xffffffff);
    expect(hi, 0xffffffff);
  });

  test('mult-sign2', () {
    mult(-1, -1);
    expect(lo, 1);
    expect(hi, 0);
  });

  test('mult-overflow', () {
    mult(0x1000000, 0x100);
    expect(lo, 0);
    expect(hi, 1);
  });

  test('multu-overflow', () {
    multu(0x1000000, 0x100);
    expect(lo, 0);
    expect(hi, 1);
  });

  test('multu-msb', () {
    multu(1, -1);
    expect(lo, 0xffffffff);
    expect(hi, 0xffffffff);
  });

  test('multu-msb2', () {
    multu(-1, -1);
    expect(lo, 0x1);
    expect(hi, 0x0);
  });
}

int lo = 0;
int hi = 0;

void mult(int a, int b) {
  // dart's `int` is not 64bit, so we need to multiply this way
  int low = a.mask16 * b;
  int high = (a >> 16) * b;
  low += (high << 16 & 0xffff0000);
  lo = low.mask32;
  hi = ((low >>> 32) + (high >>> 16)).mask32;
}

void multu(int a, int b) {
  // dart's `int` is not 64bit, so we need to multiply this way
  a = a.mask32;
  b = b.mask32;
  int low = a.mask16 * b; // 48bit
  int high = (a >>> 16) * b; // 48bit
  low += (high << 16 & 0xffff0000);
  lo = low.mask32;
  hi = ((low >>> 32) + (high >>> 16)).mask32;
}
