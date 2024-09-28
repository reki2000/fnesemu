// Dart imports:
import 'dart:typed_data';

import '../../types.dart';

class ChrRomDebugger {
  static const _width = 128;
  static const _height = 256 * 2;

// render 16 bytes chr -> buf(rgba) 256x256x2 @ x,y
  static void _renderChr(List<int> data, Uint8List buf, int x, int y) {
    for (int i = 0; i < 8; i++) {
      final ch0 = data[i];
      final ch1 = (data[i + 8]) << 1;
      for (int j = 0; j < 8; j++) {
        final c = ((ch1 >> (7 - j)) & 2) | ((ch0 >> (7 - j)) & 1);
        final bufIndex = ((y + i) * _width + (x + j)) * 4;
        buf[bufIndex + 0] = c == 1 ? 0xff : 0; // r
        buf[bufIndex + 1] = c == 2 ? 0xff : 0; // g
        buf[bufIndex + 2] = c == 3 ? 0xff : 0; // b
        buf[bufIndex + 3] = 0xff; // a
      }
    }
  }

  /// returns chr-rom image with 8x8 x 16x16 x 2(=128x256) x 2(chr/obj) ARGB format
  static ImageBuffer renderChrRom(int Function(int) readChrRom) {
    final buf = Uint8List(_width * _height * 4);

    int x = 0;
    int y = 0;
    for (int addr = 0; addr < 0x2000; addr += 16) {
      final data = List.generate(16, (i) => readChrRom(addr + i));
      _renderChr(data, buf, x, y);
      x += 8;
      if (x == _width) {
        x = 0;
        y += 8;
      }
    }

    return ImageBuffer(_width, _height, buf);
  }
}
