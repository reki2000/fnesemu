import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

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
  String get hex8 => toRadixString(16).padLeft(2, "0");
  String get hex16 => toRadixString(16).padLeft(4, "0");
  String get hex32 => toRadixString(16).padLeft(8, "0");

  int get mask8 => this & 0xff;
  int get mask16 => this & 0xffff;
  int get mask32 => this & 0xffffffff;

  int get inc => this + 1;
  int get dec => this - 1;

  int setL8(int val) => this & ~0xff | val & 0xff;
  int setH8(int val) => this & ~0xff00 | val << 8 & 0xff00;
  int setL16(int val) => this & ~0xffff | val & 0xffff;
  int setH16(int val) => this & ~0xffff0000 | val << 16 & 0xffff0000;

  int withLowByte(int val) => (this & ~0xff) | (val & 0xff);
  int withHighByte(int val) => (this & ~0xff00) | ((val & 0xff) << 8);

  int with4Bit(int val, {int lsbPosition = 0}) =>
      (this & ~(0x0f << lsbPosition)) | ((val & 0x0f) << lsbPosition);
}

extension IntImageExt on int {
  // define a bit pattern which respresents the image of the digit in 3x5 matrix
  static const digitPattern = [
    "ooo ..o ooo ooo o.o ooo ooo ooo ooo ooo ooo oo. ooo oo. ooo ooo ",
    "o.o ..o ..o ..o o.o o.. o.. ..o o.o o.o o.o o.o o.. o.o o.. o.. ",
    "o.o ..o ooo ooo ooo ooo ooo ..o ooo ooo ooo oo. o.. o.o ooo ooo ",
    "o.o ..o o.. ..o ..o ..o o.o ..o o.o ..o o.o o.o o.. o.o o.. o.. ",
    "ooo ..o ooo ooo ..o ooo ooo ..o ooo ooo o.o oo. ooo oo. ooo o.. ",
  ];

  static const patternWidth = 4;

  bool drawHexValue(int x, int y, int drawChars) {
    if (0 <= y &&
        y < digitPattern.length &&
        0 <= x &&
        x < patternWidth * drawChars) {
      final digit = (this >> (4 * (drawChars - x ~/ patternWidth - 1))) & 0x0f;
      return digitPattern[y][digit * patternWidth + (x % patternWidth)] == 'o';
    }
    return false;
  }

  bool drawValue(int x, int y, int drawChars) {
    if (0 <= y &&
        y < digitPattern.length &&
        0 <= x &&
        x < patternWidth * drawChars) {
      final digit =
          (this ~/ pow(10, (drawChars - (x ~/ patternWidth) - 1))) % 10;
      return digitPattern[y][digit * patternWidth + (x % patternWidth)] == 'o';
    }
    return false;
  }
}

/// makes range object
List<int> range(int start, int end) => [for (var i = start; i < end; i++) i];

/// utility class
class Pair<S, T> {
  final S i0;
  final T i1;
  const Pair(this.i0, this.i1);
}

// Uint8
extension Uint8ListEx on Uint8List {
  List<Uint8List> split(int size) {
    return List.generate(
        length ~/ size, (i) => sublist(i * size, (i + 1) * size));
  }

  String toBase64() {
    return base64.encode(this);
  }

  static Uint8List fromBase64(String base64) {
    return Uint8List.fromList(base64Decode(base64));
  }

  static Uint8List join(List<Uint8List> list) {
    return Uint8List.fromList(
        list.fold(List<int>.empty(growable: true), (acm, l) => acm..addAll(l)));
  }

  static List<Uint8List> ofEmptyList(int count, int size) {
    return List.generate(count, (_) => Uint8List(size));
  }
}
