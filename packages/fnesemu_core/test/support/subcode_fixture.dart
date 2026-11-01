import 'dart:typed_data';

/// Independent polynomial long division, rather than the decoder's CRC register.
Uint8List packedSubcode(List<int> payload, {int otherChannels = 0}) {
  var dividend = BigInt.zero;
  for (final byte in payload) {
    dividend = (dividend << 8) | BigInt.from(byte);
  }
  dividend <<= 16;
  final polynomial = BigInt.from(0x11021);
  for (var degree = 95; degree >= 16; degree--) {
    if ((dividend & (BigInt.one << degree)) != BigInt.zero) {
      dividend ^= polynomial << (degree - 16);
    }
  }
  final parity = dividend.toInt() ^ 0xffff;
  final q = [...payload, parity >> 8, parity & 255];
  return Uint8List.fromList([
    for (var bit = 0; bit < 96; bit++)
      (otherChannels & 0xbf) | (((q[bit ~/ 8] >> (7 - bit % 8)) & 1) << 6),
  ]);
}

/// Packs the published six-bit character cells as a literal bit string.
/// CRC packing remains the independent polynomial model above.
List<int> isrcPayload(String code, {int frame = 0, int selector = 0}) {
  const alphabet = '0123456789_______ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  final value = code.isEmpty ? '000000000000' : code;
  final fields = StringBuffer();
  for (final character in value.substring(0, 5).split('')) {
    fields.write(alphabet.indexOf(character).toRadixString(2).padLeft(6, '0'));
  }
  fields.write(selector.toRadixString(2).padLeft(2, '0'));
  for (final digit in value.substring(5).split('')) {
    fields.write(int.parse(digit).toRadixString(2).padLeft(4, '0'));
  }
  fields.write('0000');
  fields.write(
      ((frame ~/ 10) * 16 + frame % 10).toRadixString(2).padLeft(8, '0'));
  final bits = fields.toString();
  return [
    3,
    for (var byte = 0; byte < 9; byte++)
      int.parse(bits.substring(byte * 8, byte * 8 + 8), radix: 2)
  ];
}
