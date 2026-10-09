import 'dart:typed_data';
import 'package:fnesemu/core/nes/fds/fds_bios.dart';
import 'package:test/test.dart';

void main() {
  test('raw, headered 8 KiB and NROM images select BIOS from PRG, not CHR', () {
    final expected = Uint8List(8192)..fillRange(0, 8192, 0x42);
    expect(decodeFdsBios(expected), expected);
    final short = Uint8List(16 + 8192)..setAll(0, [0x4e, 0x45, 0x53, 0x1a, 1]);
    short.setAll(16, expected);
    expect(decodeFdsBios(short), expected);
    final cart = Uint8List(16 + 32768 + 8192)
      ..setAll(0, [0x4e, 0x45, 0x53, 0x1a, 2, 1]);
    cart.setAll(16 + 24576, expected);
    cart.fillRange(16 + 32768, cart.length, 0xff);
    expect(decodeFdsBios(cart), expected);
  });
  test('trainer is skipped and truncated/non-NES images are rejected', () {
    final image = Uint8List(16 + 512 + 16384)
      ..setAll(0, [0x4e, 0x45, 0x53, 0x1a, 1, 0, 4]);
    image.fillRange(16 + 512 + 8192, image.length, 0x33);
    expect(decodeFdsBios(image).every((byte) => byte == 0x33), isTrue);
    expect(() => decodeFdsBios(Uint8List(8208)), throwsFormatException);
    expect(() => decodeFdsBios(image.sublist(0, 100)), throwsFormatException);
  });
}
