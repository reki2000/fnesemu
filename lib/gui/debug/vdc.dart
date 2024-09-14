// Dart imports:
// Flutter imports:
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../nes_controller.dart';

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

void pushVdcPage(BuildContext context, NesController controller) {
  // preliminary building an RGBA color map for all 512 colors

  final Uint32List rgba = Uint32List.fromList(
    List.generate(512, (i) {
      final b = _map3to8[i & 0x07];
      final r = _map3to8[(i >> 3) & 0x07];
      final g = _map3to8[(i >> 6) & 0x07];
      return 0xff000000 | (b << 16) | (g << 8) | r;
      //return (r << 24) | (g << 16) | (b << 8) | 0xff;
    }, growable: false),
  );

  final imageNotifier = ValueNotifier<ui.Image?>(null);

  int size = 16;
  int width = size * 16 + size * 2 + size * 16;
  int height = size * 16;

  final buf = Uint32List(width * height);
  final colorTable = controller.dumpColorTable();

  for (int p = 0; p < 16; p++) {
    for (int c = 0; c < 16; c++) {
      int bg = rgba[colorTable[p << 4 | c]];
      int sp = rgba[colorTable[p << 4 | c] | 0x100];
      for (int y = 0; y < size - 1; y++) {
        for (int x = 0; x < size - 1; x++) {
          buf[c * size + x + (p * size + y) * width] = bg;
          buf[c * size + x + (p * size + y) * width + (size * 16 + size * 2)] =
              sp;
        }
      }
    }
  }

  ui.decodeImageFromPixels(buf.buffer.asUint8List(), width, height,
      ui.PixelFormat.rgba8888, (image) => imageNotifier.value = image);

  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) {
        return Scaffold(
          appBar: AppBar(title: const Text('VDC')),
          body: Container(
            alignment: Alignment.center,
            margin: const EdgeInsets.all(10.0),
            child: Column(children: [
              // Image.memory(
              //   Uint8List.view(buf.buffer),
              // ),
              ValueListenableBuilder(
                valueListenable: imageNotifier,
                builder: (context, image, child) {
                  return image != null
                      ? RawImage(image: image)
                      : const CircularProgressIndicator();
                },
              ),
            ]),
          ),
        );
      },
    ),
  );
}
