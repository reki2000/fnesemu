// Dart imports:
// Flutter imports:
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/debugger.dart';
import '../../styles.dart';
import '../../util.dart';

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

Future<ui.Image> renderColorTable(colorTable, int selected) {
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
      int color = _rgba[colorTable[p << 4 | c]];

      for (int y = 0; y < size - 1; y++) {
        for (int x = 0; x < size - 1; x++) {
          buf[size + c * size + x + (p * size + y) * width] = color;
        }
      }
    }
  }

  return _decodeImage(buf.buffer.asUint8List(), width, height);
}

Future<ui.Image> renderVram(colorTable, List<int> vram, int paletteNo) {
  int tileSize = 8;
  int width = (tileSize * 16 + tileSize * 1) * 4;
  int height = (tileSize * 16 + tileSize * 1) * 4;

  final buf = Uint32List(width * height);
  final palette = paletteNo << 4;

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
              final c = colorTable[palette | p];
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

String _dumpSat(List<int> sat, bool second) {
  final buf = StringBuffer();
  final offset = second ? 32 : 0;

  for (int i = offset; i < offset + 32; i++) {
    final sp = _Sprite.of(sat, i * 4);
    final xy = "${sp.x.toString().padLeft(4)},${sp.y.toString().padLeft(4)}";
    final patNo =
        "${sp.patternNo.toString().padLeft(4)} ${hex16(sp.patternNo << 6)}";
    buf.write(
        "${i.toString().padLeft(2)} $xy  $patNo ${sp.paletteNo.toString().padLeft(2)} ${sp.vFlip ? "v" : " "}${sp.hFlip ? "h" : " "} \n");
  }

  return buf.toString();
}

class _Sprite {
  late final int no;
  late final int x;
  late final int y;
  late final int patternNo;
  late final int paletteNo;
  late final bool cgModeTreal01Zero;
  late final bool vFlip;
  late final bool hFlip;
  late final int height;
  late final int width;
  late final bool priority;

  _Sprite.of(List<int> sat, int i) {
    no = i >> 2;
    y = sat[i] & 0x3ff;
    x = sat[i + 1] & 0x3ff;

    cgModeTreal01Zero = sat[i + 2] & 0x01 != 0;
    vFlip = (sat[i + 3] & 0x8000) != 0;
    hFlip = (sat[i + 3] & 0x0800) != 0;
    priority = (sat[i + 3] & 0x80) != 0;
    paletteNo = ((sat[i + 3] & 0x0f) << 4) | 0x100;

    height = switch ((sat[i + 3] >> 12) & 0x03) { 0 => 16, 1 => 32, _ => 64 };
    width = switch ((sat[i + 3] >> 8) & 0x01) { 0 => 16, _ => 32 };

    int patternMask = 0;
    if (height == 64) {
      patternMask |= 0x06;
    } else if (height == 32) {
      patternMask |= 0x02;
      ;
    }
    if (width == 32) {
      patternMask |= 0x01;
    }
    patternNo = (sat[i + 2] >> 1) & 0x3ff & ~patternMask;
  }
}

class DebugVdc extends StatelessWidget {
  final Debugger debugger;

  DebugVdc({super.key, required this.debugger});

  final _paletteNo = ValueNotifier(0);

  Widget _paletteNoListener(Function builder) => ValueListenableBuilder(
        valueListenable: _paletteNo,
        builder: (context, value, child) => builder(value),
      );

  @override
  Widget build(BuildContext context) => Container(
        alignment: Alignment.center,
        margin: const EdgeInsets.all(10.0),
        child: Column(children: [
          Row(children: [
            Text(_dumpSat(debugger.dumpSpriteTable(), false),
                style: debugStyle),
            Text(_dumpSat(debugger.dumpSpriteTable(), true), style: debugStyle),
            Row(children: [
              Column(children: [
                Row(children: [
                  IconButton(
                      icon: const Icon(Icons.arrow_upward),
                      onPressed: () {
                        _paletteNo.value = (_paletteNo.value - 1) & 0x1f;
                      }),
                  IconButton(
                      icon: const Icon(Icons.arrow_downward),
                      onPressed: () {
                        _paletteNo.value = (_paletteNo.value + 1) & 0x1f;
                      }),
                  _paletteNoListener(
                      (value) => Text("$value", style: debugStyle)),
                ]),
                _paletteNoListener((value) => _futureImage(
                    renderColorTable(debugger.dumpColorTable(), value))),
              ]),
              _paletteNoListener((value) => _futureImage(renderVram(
                  debugger.dumpColorTable(), debugger.dumpVram(), value))),
            ]),
          ]),
          _futureImage(renderBg(
              debugger.dumpColorTable(),
              debugger.dumpVram(),
              debugger.core.vdc.bgWidthMask + 1,
              debugger.core.vdc.bgHeightMask + 1)),
        ]),
      );
}
