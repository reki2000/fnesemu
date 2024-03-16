/// print a 8 bit value as 1 hexadecimal digit
String hex8(int x) {
  return x.toRadixString(16).padLeft(2, "0");
}

/// print a 16 bit value in 2 hexadecimal digits
String hex16(int x) {
  return x.toRadixString(16).padLeft(4, "0");
}

/// flip 8 bit from b7..b0 to b0..b7
int flip8(int p0) {
  final p = ((p0 & 0x55) << 1) | ((p0 & 0xaa) >> 1);
  final pp = ((p & 0x33) << 2) | ((p & 0xcc) >> 2);
  return ((pp & 0x0f) << 4) | ((pp & 0xf0) >> 4);
}

/// bit checkers
bool bit7(int a) => a & 0x80 != 0;
bool bit6(int a) => a & 0x40 != 0;
bool bit5(int a) => a & 0x20 != 0;
bool bit4(int a) => a & 0x10 != 0;
bool bit3(int a) => a & 0x08 != 0;
bool bit2(int a) => a & 0x04 != 0;
bool bit1(int a) => a & 0x02 != 0;
bool bit0(int a) => a & 0x01 != 0;

// sets partial bits in a int value
extension IntExt on int {
  int withLowByte(int val) => (this & ~0xff) | (val & 0xff);
  int withHighByte(int val) => (this & ~0xff00) | ((val & 0xff) << 8);

  int with4Bit(int val, {int lsbPosition = 0}) =>
      (this & ~(0x0f << lsbPosition)) | ((val & 0x0f) << lsbPosition);
}

/// makes range object
List<int> range(int start, int end) => [for (var i = start; i < end; i++) i];

/// utility class
class Pair<S, T> {
  final S i0;
  final T i1;
  Pair(this.i0, this.i1);
}
