// Flutter imports:
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'dart:ui' as ui;

// Project imports:
import '../../cpu/nes.dart';

const _width = 128;
const _height = 256 * 2;

// render 16 bytes chr -> buf(rgba) 256x256x2 @ x,y
void _renderChr(List<int> data, Uint8List buf, int x, int y) {
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

Uint8List _renderChrRom(Nes emulator) {
  final buf = Uint8List(_width * _height * 4);

  int x = 0;
  int y = 0;
  for (int addr = 0; addr < 0x2000; addr += 16) {
    final data = List.generate(16, (i) => emulator.bus.readVram(addr + i));
    _renderChr(data, buf, x, y);
    x += 8;
    if (x == _width) {
      x = 0;
      y += 8;
    }
  }

  return buf;
}

Widget _uint8Image(Uint8List buf) {
  final completer = Completer<Widget>();

  ui.decodeImageFromPixels(buf, _width, _height, ui.PixelFormat.rgba8888,
      (img) => completer.complete(RawImage(image: img, scale: 0.5)));

  return FutureBuilder<Widget>(
    future: completer.future,
    builder: (ctx, snapshot) => snapshot.data ?? const Text("loading.."),
  );
}

void showVram(BuildContext context, Nes emulator) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) {
        return Scaffold(
          appBar: AppBar(title: const Text('VRAM')),
          body: Container(
            alignment: Alignment.center,
            margin: const EdgeInsets.all(10.0),
            child: _uint8Image(_renderChrRom(emulator)),
          ),
        );
      },
    ),
  );
}
