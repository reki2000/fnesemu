import 'dart:typed_data';

import '../../types.dart';
import 'vdc.dart';
import 'vdc_render.dart';

extension VdcDebug on Vdc {
  ImageBuffer renderBg() {
    final bgWidth = bgWidthMask + 1;
    final bgHeight = bgHeightMask + 1;

    const tileSize = 8;
    const imageWidth = 128 * tileSize;
    const imageHeight = 64 * tileSize;

    // final blockSizeX = 128 ~/ bgWidth;
    // final blockSizeY = 64 ~/ bgHeight;

    final buf = Uint32List(imageWidth * imageHeight);

    // for (int blockY = 0; blockY < blockSizeY; blockY++) {
    //   for (int blockX = 0; blockX < blockSizeX; blockX++) {
    const vramOffset = 0;
    const imageOffset = 0;
    //     final vramOffset = (blockX + blockY * blockSizeX) * 16 * bgWidth * bgHeight;
    //     final imageOffset = blockX * tileSize * bgWidth + (blockY * tileSize * bgHeight) * imageWidth;

    for (int ty = 0; ty < bgHeight; ty++) {
      for (int tx = 0; tx < bgWidth; tx++) {
        final pattern = vram[tx + ty * bgWidth + vramOffset];
        final palette = pattern >> 12 << 4;

        for (int y = 0; y < tileSize; y++) {
          final addr = (pattern & 0xfff) * 16 + y;
          final pattern01 = vram[addr];
          final pattern23 = vram[addr + 8];

          for (int x = 0; x < tileSize; x++) {
            final shiftBits = (7 - (x & 7));
            final p01 = pattern01 >> shiftBits;
            final p23 = pattern23 >> shiftBits;

            final color = (p01 & 0x01) |
                (p01 >> 7) & 0x02 |
                (p23 << 2) & 0x04 |
                (p23 >> 5) & 0x08;

            final c = colorTable[((color == 0) ? 0 : palette) | color];
            buf[imageOffset +
                tx * tileSize +
                x +
                (ty * tileSize + y) * imageWidth] = rgba[c];
          }
        }
      }
      //   }
      // }
    }

    return ImageBuffer(imageWidth, imageHeight, buf.buffer.asUint8List());
  }
}
