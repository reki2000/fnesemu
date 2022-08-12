// Dart imports:
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

// Flutter imports:
import 'package:flutter/material.dart';

// Project imports:
import '../nes_controller.dart';

Widget _uint8Image(Uint8List buf) {
  final completer = Completer<Widget>();

  ui.decodeImageFromPixels(buf, 128, 256 * 2, ui.PixelFormat.rgba8888,
      (img) => completer.complete(RawImage(image: img, scale: 0.5)));

  return FutureBuilder<Widget>(
    future: completer.future,
    builder: (ctx, snapshot) => snapshot.data ?? const Text("loading..."),
  );
}

void pushVramPage(BuildContext context, NesController controller) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) {
        return Scaffold(
          appBar: AppBar(title: const Text('VRAM')),
          body: Container(
            alignment: Alignment.center,
            margin: const EdgeInsets.all(10.0),
            child: _uint8Image(controller.renderChrRom()),
          ),
        );
      },
    ),
  );
}
