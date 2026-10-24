import 'dart:convert';

import 'package:fnesemu_core/src/util/state.dart';
import 'package:test/test.dart';

void main() {
  test('media hash preserves signed 64-bit identities on exact integer hosts', () {
    final offset = BigInt.parse('cbf29ce484222325', radix: 16).toSigned(64);
    final exactIntegers = BigInt.from(offset.toInt()) == offset;
    if (!exactIntegers) {
      expect(() => stateMediaHash([]), throwsUnsupportedError);
      expect(() => stateMediaHash(utf8.encode('foobar')), throwsUnsupportedError);
      return;
    }
    for (final (input, expected) in [
      ('', 'cbf29ce484222325'),
      ('a', 'af63dc4c8601ec8c'),
      ('foobar', '85944171f73967e8'),
    ]) {
      expect(stateMediaHash(utf8.encode(input)),
          BigInt.parse(expected, radix: 16).toSigned(64).toInt());
    }
    final bytes = List.generate(1024, (i) => i & 255);
    var expected = BigInt.parse('cbf29ce484222325', radix: 16);
    final prime = BigInt.parse('100000001b3', radix: 16);
    for (final byte in bytes) {
      expected = ((expected ^ BigInt.from(byte)) * prime).toUnsigned(64);
    }
    expect(stateMediaHash(bytes), expected.toSigned(64).toInt());
  });
}
