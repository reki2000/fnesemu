import 'dart:convert';

import 'package:fnesemu_core/src/util/crc32.dart';
import 'package:test/test.dart';

void main() {
  test('the CRC-32 of the check string and of nothing', () {
    expect(crc32(ascii.encode('123456789')), 0xcbf43926);
    expect(crc32Hex(ascii.encode('123456789')), 'cbf43926');
    expect(crc32Hex([]), '00000000');
  });

  test('a value with leading zeros keeps 8 digits', () {
    expect(crc32Hex([0x01]), hasLength(8));
  });
}
