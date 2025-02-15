// Package imports:
// Project imports:
import 'package:fnesemu/util/util.dart';
import 'package:test/test.dart';

void main() {
  test('partial bit set ', () {
    expect(0x321.withLowByte(0x5a), 0x35a);
    expect((-1).withLowByte(0x5a), 0xffffffffffffff5a);
  });

  test('partial bit set ', () {
    expect(0x321.withHighByte(0x5a), 0x5a21);
    expect((-1).withHighByte(0x5a), 0xffffffffffff5aff);
  });
}
