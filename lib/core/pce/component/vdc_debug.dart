import 'dart:typed_data';

import '../../../util.dart';
import '../../types.dart';
import 'vdc.dart';
import 'vdc_render.dart';

extension VdcDebug on Vdc {
  ImageBuffer renderColorTable(int selected) {
    int size = 8;
    int width = size + size * 16;
    int height = size * 32;

    final buf = Uint32List(width * height);

    for (int p = 0; p < 32; p++) {
      if (p == selected) {
        for (int x = 0; x < 7; x++) {
          buf[x + (p * size + 4) * width] = 0xff000000;
        }
      }

      for (int c = 0; c < 16; c++) {
        int color = rgba[colorTable[p << 4 | c]];

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

  ImageBuffer renderVram(bool useSecondBgColor, int paletteNo) {
    if (vram.length < 0x8000) {
      return ImageBuffer(0, 0, Uint8List(0));
    }

    int tileSize = 8;
    int width = (tileSize * 16 + tileSize * 1) * 4;
    int height = (tileSize * 16 + tileSize * 1) * 4;

    final buf = Uint32List(width * height);
    final palette = paletteNo << 4;

    for (int baseY = 0; baseY < 4; baseY++) {
      for (int baseX = 0; baseX < 4; baseX++) {
        final vramOffset = (baseY * 4 + baseX) * 0x1000;
        final imageOffset = baseX * (tileSize * (16 + 1)) +
            baseY * (tileSize * (16 + 1)) * width;

        for (int ty = 0; ty < 16; ty++) {
          for (int tx = 0; tx < 16; tx++) {
            for (int y = 0; y < tileSize; y++) {
              final addr = (tx + ty * 16) * 16 + y;
              final pattern01 = vram[vramOffset | addr];
              final pattern23 = vram[vramOffset | (addr + 8)];

              for (int x = 0; x < tileSize; x++) {
                final shiftBits = 7 - x;
                final p01 = pattern01 >> shiftBits;
                final p23 = pattern23 >> shiftBits;

                final color = (p01 & 0x01) |
                    (p01 >> 7) & 0x02 |
                    (p23 << 2) & 0x04 |
                    (p23 >> 5) & 0x08;
                final c = (useSecondBgColor && color == 0)
                    ? 0xffffffff
                    : rgba[colorTable[((color == 0) ? 0 : palette) | color]];
                buf[tx * tileSize +
                    x +
                    (ty * tileSize + y) * width +
                    imageOffset] = c;
              }
            }
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

  List<String> spriteInfo() {
    final buf = List<String>.filled(64, "");

    for (int i = 0; i < 64; i++) {
      final sp = Sprite.of(sat, i * 4);
      final xy = "${sp.x.toString().padLeft(4)},${sp.y.toString().padLeft(4)}";
      final patNo =
          "${sp.patternNo.toString().padLeft(4)} ${hex16(sp.patternNo << 6)}";
      buf[i] =
          "${i.toString().padLeft(2)} $xy  $patNo ${sp.paletteNo.toString().padLeft(2)} ${sp.vFlip ? "v" : " "}${sp.hFlip ? "h" : " "}";
    }

    return buf;
  }

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
