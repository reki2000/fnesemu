// Dart imports:
// Flutter imports:
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'debugger.dart';

const _map3to8 = [
  0x00,
  0x24,
  0x49,
  0x6d,
  0x92,
  0xb6,
  0xdb,
  0xff,
];

// preliminary building an RGBA color map for all 512 colors
final Uint32List _rgba = Uint32List.fromList(
  List.generate(512, (i) {
    final b = _map3to8[i & 0x07];
    final r = _map3to8[(i >> 3) & 0x07];
    final g = _map3to8[(i >> 6) & 0x07];
    return 0xff000000 | (b << 16) | (g << 8) | r;
  }, growable: false),
);

Future<ui.Image> renderColorTable(colorTable) {
  int size = 8;
  int width = size * 16 + size * 1 + size * 16;
  int height = size * 16;

  final buf = Uint32List(width * height);

  for (int p = 0; p < 16; p++) {
    for (int c = 0; c < 16; c++) {
      int bg = _rgba[colorTable[p << 4 | c]];
      int sp = _rgba[colorTable[p << 4 | c] | 0x100];
      for (int y = 0; y < size - 1; y++) {
        for (int x = 0; x < size - 1; x++) {
          buf[c * size + x + (p * size + y) * width] = bg;
          buf[c * size + x + (p * size + y) * width + (size * 16 + size * 1)] =
              sp;
        }
      }
    }
  }

  return _decodeImage(buf.buffer.asUint8List(), width, height);
}

Future<ui.Image> renderVram(colorTable, List<int> vram) {
  int tileSize = 8;
  int width = (tileSize * 16 + tileSize * 1) * 4;
  int height = (tileSize * 16 + tileSize * 1) * 4;

  final buf = Uint32List(width * height);

  for (int baseY = 0; baseY < 4; baseY++) {
    for (int baseX = 0; baseX < 4; baseX++) {
      final vramOffset = (baseY * 4 + baseX) * 0x800;
      final imageOffset = baseX * (tileSize * 16 + tileSize * 1) +
          baseY * (tileSize * 16 + tileSize * 1) * width;

      for (int ty = 0; ty < 16; ty++) {
        for (int tx = 0; tx < 16; tx++) {
          for (int y = 0; y < 8; y++) {
            final addr = (tx + ty * 16) * 16 + y;
            final p01 = vram[vramOffset | addr];
            final p23 = vram[vramOffset | addr + 8];

            for (int x = 0; x < 8; x++) {
              final p0 = (p01 >> (8 + tileSize - x - 1)) & 1;
              final p1 = (p01 >> (0 + tileSize - x - 1)) & 1;
              final p2 = (p23 >> (8 + tileSize - x - 1)) & 1;
              final p3 = (p23 >> (0 + tileSize - x - 1)) & 1;
              final p = p0 | (p1 << 1) | (p2 << 2) | (p3 << 3);
              final c = colorTable[p];
              buf[tx * 8 + x + (ty * 8 + y) * width + imageOffset] = _rgba[c];
            }
          }
        }
      }
    }
  }

  return _decodeImage(buf.buffer.asUint8List(), width, height);
}

Future<ui.Image> renderBg(
    colorTable, List<int> vram, int bgWidth, int bgHeight) {
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

          final c = colorTable[palette | color];
          buf[imageOffset +
              tx * tileSize +
              x +
              (ty * tileSize + y) * imageWidth] = _rgba[c];
        }
      }
    }
    //   }
    // }
  }

  return _decodeImage(buf.buffer.asUint8List(), imageWidth, imageHeight);
}

_decodeImage(Uint8List buf, int width, int height) {
  final completer = Completer<ui.Image>();

  ui.decodeImageFromPixels(buf.buffer.asUint8List(), width, height,
      ui.PixelFormat.rgba8888, (image) => completer.complete(image));

  return completer.future;
}

_futureImage(Future<ui.Image> future) {
  return FutureBuilder(
    future: future,
    builder: (context, image) => RawImage(image: image.data),
  );
}

class DebugVdc extends StatelessWidget {
  final Debugger debugger;

  const DebugVdc({super.key, required this.debugger});

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.center,
      margin: const EdgeInsets.all(10.0),
      child: Column(children: [
        Row(children: [
          _futureImage(renderColorTable(debugger.dumpColorTable())),
          _futureImage(
              renderVram(debugger.dumpColorTable(), debugger.dumpVram())),
        ]),
        _futureImage(renderBg(
            debugger.dumpColorTable(),
            debugger.dumpVram(),
            debugger.core.vdc.bgWidthMask + 1,
            debugger.core.vdc.bgHeightMask + 1)),
      ]),
    );
  }
}
