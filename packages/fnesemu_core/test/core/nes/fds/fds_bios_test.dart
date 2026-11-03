import 'dart:typed_data';

import 'package:fnesemu_core/src/core/nes/fds/fds_bios.dart';
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
}
