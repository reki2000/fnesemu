import 'dart:typed_data';

import '../types.dart';
import 'vdp.dart';
import 'vdp_renderer.dart';

extension VdpDebug on Vdp {
  ImageBuffer renderColorTable(int selected) {
    int size = 8;
    int width = size + size * 16;
    int height = size * 32;

    final buf = Uint32List(width * height);

    for (int p = 0; p < 4; p++) {
      if (p == selected) {
        for (int x = 0; x < 7; x++) {
          buf[x + (p * size + 4) * width] = 0xff000000;
        }
      }

      for (int c = 0; c < 16; c++) {
        int color = rgba[cram[p << 4 | c]];

        for (int y = 0; y < size - 1; y++) {
          for (int x = 0; x < size - 1; x++) {
            buf[size + c * size + x + (p * size + y) * width] = color;
          }
        }
      }
    }

    return ImageBuffer(
      width,
      height,
      buf.buffer.asUint8List(),
    );
  }
}
