import 'package:fnesemu/util.dart';
import 'package:test/test.dart';

void main() {
  test('partial bit set ', () {
    expect(setLowByte(0x321, 0x5a), 0x35a);
    expect(setLowByte(-1, 0x5a), 0xffffffffffffff5a);

    expect(setHighByte(0x321, 0x5a), 0x5a21);
    expect(setHighByte(-1, 0x5a), 0xffffffffffff5aff);
  });
}
