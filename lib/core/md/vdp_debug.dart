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

  ImageBuffer renderVram(bool useGlayscale, int paletteNo) {
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
                final c = useGlayscale
                    ? (0xff000000 | color << 20 | color << 12 | color << 4)
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

  List<String> debugSpriteInfo() {
    final baseAddr = reg[5] << 9 & 0xfc00;
    final result = List.generate(80, (i) {
      final base = baseAddr + i * 8;
      final sp = Sprite.of(
          vram.getUInt16BE(base.mask16),
          vram.getUInt16BE((base + 2).mask16),
          vram.getUInt16BE((base + 4).mask16),
          vram.getUInt16BE((base + 6).mask16));
      final no = "${i.toString().padLeft(2)}->${sp.next.toString().padLeft(2)}";
      final flags =
          "${sp.vFlip ? "v" : "-"}${sp.hFlip ? "h" : "-"}${sp.priority ? "p" : "-"}";
      final xy = "${sp.x.toString().padLeft(3)},${sp.y.toString().padLeft(3)}";
      return "#$no $xy ${sp.patternAddr.hex16} $flags ${sp.width.toString().padLeft(2)}x${sp.height.toString().padLeft(2)} ";
    });
    return result;
  }

  ImageBuffer renderBg() {
    const tileSize = 8;
    // bgA(w128) + sprite(512) + window(w64)
    const imageWidth = 128 * tileSize + 64 * tileSize + 512;
    const imageHeight = 64 * tileSize;

    final buf = Uint32List(imageWidth * imageHeight);
    buf.fillRange(0, buf.length, 0xff000000);

    final nameA = reg[2] << 10 & 0xe000;
    final nameB = reg[4] << 13 & 0xe000;
    final window = reg[3] << 10 & 0xf800;

    for (int plane = 0; plane < 3; plane++) {
      final nameAddressBase = [nameA, nameB, window][plane];

      final bgHshift = [5, 6, 7, 7][plane == 2 ? 1 : reg[16] & 0x03];
      final bgVShift = [5, 6, 7, 7][plane == 2 ? 0 : reg[16] >> 4 & 0x03];

      final bgWidth = 1 << bgHshift;
      final bgHeight = 1 << bgVShift;

      // if bgHshift == 7, show planeA and planeB vertically stacked.
      final imageOffset = switch (plane) {
        0 => 0,
        1 => bgHshift == 7 ? 32 * tileSize * imageWidth : 64 * tileSize,
        _ => 128 * tileSize + 512
      };

      // render BG tiles
      for (int ty = 0; ty < bgHeight; ty++) {
        for (int tx = 0; tx < bgWidth; tx++) {
          final name = nameAddressBase | ty << (bgHshift + 1) | tx << 1;
          final d0 = vram[name];
          final d1 = vram[name.inc];
          final palette = d0 >> 1 & 0x30;
          final addr = (d0 << 8 & 0x0700 | d1) << 5;
          final hFlip = d0 & 0x08 != 0;
          final vFlip = d0 & 0x10 != 0;

          for (int y = 0; y < tileSize; y++) {
            final pattern = vram.getUInt32BE(addr + ((vFlip ? 7 - y : y) << 2));

            for (int x = 0; x < tileSize; x++) {
              final shift = hFlip ? x : 7 - x;
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

      // render scrolled areas

      // render window viewport
    }

    // render sprites box
    const spriteImageOffset = 128 * tileSize;
    final spriteBaseAddr = reg[5] << 9 & 0xfc00;
    void pset(int x, int y, int c) {
      int index = spriteImageOffset + x + y * imageWidth;
      buf[index] =
          ((buf[index] & 0xffffff) + 0x404040).clip(0, 0xffffff) | 0xff000000;
    }

    int spriteNo = 0;
    for (int i = 0; i < 80; i++) {
      final base = spriteBaseAddr + spriteNo * 8;
      final sp = Sprite.of(
          vram.getUInt16BE((base + 0).mask16),
          vram.getUInt16BE((base + 2).mask16),
          vram.getUInt16BE((base + 4).mask16),
          vram.getUInt16BE((base + 6).mask16));

      for (final y in [sp.y, sp.y + sp.height - 1]) {
        for (int x = sp.x; x < sp.x + sp.width; x++) {
          pset(x, y, 0x404040);
        }
      }

      for (final x in [sp.x, sp.x + sp.width - 1]) {
        for (int y = sp.y; y < sp.y + sp.height; y++) {
          pset(x, y, 0x404040);
        }
      }

      spriteNo = sp.next;
      if (spriteNo == 0) {
        break;
      }
    }

    return ImageBuffer(imageWidth, imageHeight, buf.buffer.asUint8List());
  }
}
