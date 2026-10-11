import 'dart:typed_data';

// the table of the CRC-32 (IEEE 802.3) polynomial, reflected
final _table = Uint32List.fromList(List.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = c & 1 != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
  }
  return c;
}));

/// the CRC-32 of [data], as used by zip and png
int crc32(List<int> data) {
  var c = 0xffffffff;
  for (final b in data) {
    c = _table[(c ^ b) & 0xff] ^ (c >> 8);
  }
  return c ^ 0xffffffff;
}

/// [crc32] as 8 lower case hex digits
String crc32Hex(List<int> data) =>
    crc32(data).toRadixString(16).padLeft(8, '0');
