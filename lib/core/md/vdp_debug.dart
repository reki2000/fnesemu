import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';
import 'package:fnesemu/util/util.dart';

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

  ImageBuffer renderVram(bool useSecondBgColor, int paletteNo) {
    if (vram.length < 0x8000) {
      return ImageBuffer(0, 0, Uint8List(0));
    }

    int tileSize = 8;
    int width = (tileSize * 16) * 4;
    int height = (tileSize * 16) * 2;

    final buf = Uint32List(width * height);
    final palette = paletteNo << 4;

    for (int baseY = 0; baseY < 2; baseY++) {
      for (int baseX = 0; baseX < 4; baseX++) {
        final vramOffset = (baseY * 4 + baseX) * 0x2000;
        final imageOffset =
            baseX * (tileSize * 16) + baseY * (tileSize * 16) * width;

        for (int ty = 0; ty < 16; ty++) {
          for (int tx = 0; tx < 16; tx++) {
            for (int y = 0; y < tileSize; y++) {
              final addr = (tx + ty * 16) * 32 + y * 4;
              final pattern = vram.getUInt32BE(addr + vramOffset);

              for (int x = 0; x < tileSize; x++) {
                final shiftBits = 7 - x;

                final color = (pattern >> (shiftBits << 2)) & 0x0f;
                final c = (useSecondBgColor && color == 0)
                    ? 0xffffffff
                    : rgba[cram[((color == 0) ? 0 : palette) | color]];
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

  // List<String> spriteInfo() {
  //   final buf = List<String>.filled(64, "");

  //   for (int i = 0; i < 64; i++) {
  //     final sp = Sprite.of(sat, i * 4);
  //     final xy = "${sp.x.toString().padLeft(4)},${sp.y.toString().padLeft(4)}";
  //     final patNo =
  //         "${sp.patternNo.toString().padLeft(4)} ${hex16(sp.patternNo << 6)}";
  //     buf[i] =
  //         "${i.toString().padLeft(2)} $xy  $patNo ${sp.paletteNo.toString().padLeft(2)} ${sp.vFlip ? "v" : " "}${sp.hFlip ? "h" : " "}";
  //   }

  //   return buf;
  // }

  ImageBuffer renderBg() {
    final bgHshift = [5, 6, 7, 7][reg[16] & 0x03];
    const bgVShift = 5;
    final bgWidth = 1 << bgHshift;
    const bgHeight = 1 << bgVShift;

    const tileSize = 8;
    const imageWidth = 128 * tileSize;
    const imageHeight = 64 * tileSize;

    final buf = Uint32List(imageWidth * imageHeight);

    // final nameA = reg[2] << 10 & 0xe000;
    // final nameB = reg[4] << 13 & 0xe000;
    for (int plane = 0; plane < 2; plane++) {
      final nameAddressBase =
          switch (plane) { 0 => reg[2] << 10, _ => reg[4] << 13 } & 0xe000;
      final imageOffset = plane * 32 * tileSize * imageWidth;

      for (int ty = 0; ty < bgHeight; ty++) {
        for (int tx = 0; tx < bgWidth; tx++) {
          final name = nameAddressBase | ty << (bgHshift + 1) | tx << 1;
          final d0 = vram[name];
          final d1 = vram[name.inc];
          final palette = d0 >> 1 & 0x30;
          final addr = (d0 << 8 & 0x0700 | d1) << 5;

          for (int y = 0; y < tileSize; y++) {
            final pattern = vram.getUInt32BE(addr + (y << 2));

            for (int x = 0; x < tileSize; x++) {
              final shift = 7 - x;
              final color = (pattern >> (shift << 2)) & 0x0f;
              final c = cram[((color == 0) ? 0 : palette) | color];

              buf[imageOffset +
                  tx * tileSize +
                  x +
                  (ty * tileSize + y) * imageWidth] = rgba[c];
            }
          }
        }
      }
    }

    return ImageBuffer(imageWidth, imageHeight, buf.buffer.asUint8List());
  }
}
