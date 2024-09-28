// Dart imports:
// Flutter imports:
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/debugger.dart';
import '../../core/types.dart';
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

ImageBuffer renderColorTable(colorTable, int selected) {
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

  return ImageBuffer(
    width,
    height,
    buf.buffer.asUint8List(),
  );
}

ImageBuffer renderVram(colorTable, List<int> vram, int paletteNo) {
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
            final pattern01 = vram[vramOffset | addr];
            final pattern23 = vram[vramOffset | addr + 8];

            for (int x = 0; x < tileSize; x++) {
              final shiftBits = (7 - (x & 7));
              final p01 = pattern01 >> shiftBits;
              final p23 = pattern23 >> shiftBits;

              final color = (p01 & 0x01) |
                  (p01 >> 7) & 0x02 |
                  (p23 << 2) & 0x04 |
                  (p23 >> 5) & 0x08;
              final c = colorTable[((color == 0) ? 0 : palette) | color];
              buf[tx * 8 + x + (ty * 8 + y) * width + imageOffset] = _rgba[c];
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

_imageBufferRenderer(ImageBuffer buf) {
  final completer = Completer<ui.Image>();

  ui.decodeImageFromPixels(buf.buffer, buf.width, buf.height,
      ui.PixelFormat.rgba8888, (image) => completer.complete(image));

  return FutureBuilder(
    future: completer.future,
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
    }
    if (width == 32) {
      patternMask |= 0x01;
    }
    patternNo = (sat[i + 2] >> 1) & 0x3ff & ~patternMask;
  }
}

class DebugVdc extends StatefulWidget {
  final Debugger debugger;

  const DebugVdc({super.key, required this.debugger});

  @override
  State<DebugVdc> createState() => _DebugVdc();
}

class _DebugVdc extends State<DebugVdc> {
  int _paletteNo = 0;
  bool _useSecond = false;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
  }

  List<int> _colorTable(bool second) {
    final colorTable = List<int>.from(widget.debugger.dumpColorTable());
    if (second) {
      colorTable[0] = 0x1ff;
    }
    return colorTable;
  }

  @override
  Widget build(BuildContext context) => Container(
        alignment: Alignment.center,
        margin: const EdgeInsets.all(10.0),
        child: Column(children: [
          Row(children: [
            Text(_dumpSat(widget.debugger.dumpSpriteTable(), false),
                style: debugStyle),
            Text(_dumpSat(widget.debugger.dumpSpriteTable(), true),
                style: debugStyle),
            Row(children: [
              Column(children: [
                Row(children: [
                  Switch(
                      value: _useSecond,
                      onChanged: (onoff) => setState(() => _useSecond = onoff)),
                  IconButton(
                      icon: const Icon(Icons.arrow_upward),
                      onPressed: () => setState(() {
                            _paletteNo = (_paletteNo - 1) & 0x1f;
                          })),
                  IconButton(
                      icon: const Icon(Icons.arrow_downward),
                      onPressed: () => setState(() {
                            _paletteNo = (_paletteNo + 1) & 0x1f;
                          })),
                  Text("$_paletteNo", style: debugStyle),
                ]),
                _imageBufferRenderer(
                    renderColorTable(_colorTable(_useSecond), _paletteNo)),
              ]),
              _imageBufferRenderer(renderVram(_colorTable(_useSecond),
                  widget.debugger.dumpVram(), _paletteNo)),
            ]),
          ]),
          _imageBufferRenderer(widget.debugger.renderBg()),
        ]),
      );
}
