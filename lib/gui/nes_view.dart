// Dart imports:
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

// Flutter imports:
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Project imports:
import '../cpu/pad_button.dart';
import '../styles.dart';
import 'nes_controller.dart';

class NesView extends StatelessWidget {
  final NesController controller;
  NesView({Key? key, required this.controller}) : super(key: key);

  bool _showDebugView = false;

  static final keys = {
    PhysicalKeyboardKey.arrowDown: PadButton.down,
    PhysicalKeyboardKey.arrowUp: PadButton.up,
    PhysicalKeyboardKey.arrowLeft: PadButton.left,
    PhysicalKeyboardKey.arrowRight: PadButton.right,
    PhysicalKeyboardKey.keyX: PadButton.a,
    PhysicalKeyboardKey.keyZ: PadButton.b,
    PhysicalKeyboardKey.keyA: PadButton.select,
    PhysicalKeyboardKey.keyS: PadButton.start,
  };

  bool _keyHandler(KeyEvent e) {
    for (final entry in keys.entries) {
      if (entry.key == e.physicalKey) {
        switch (e.runtimeType) {
          case KeyDownEvent:
            controller.padDown(entry.value);
            break;
          case KeyUpEvent:
            controller.padUp(entry.value);
            break;
        }
        return true;
      }
    }
    return false;
  }

  Future<ui.Image> renderVideo(Uint8List buf) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
        buf, 256, 240, ui.PixelFormat.rgba8888, completer.complete);
    return completer.future;
  }

  @override
  Widget build(BuildContext context) {
    void _setFile() async {
      final picked = await FilePicker.platform.pickFiles(withData: true);
      if (picked != null) {
        controller.reset();
        try {
          controller.setRom(picked.files.first.bytes!);
          controller.run();
        } catch (e) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(e.toString())));
        }
      }
    }

    return RepaintBoundary(
      child: Column(
        children: [
          ElevatedButton(child: const Text("Load"), onPressed: _setFile),
          // main view
          Focus(
              onFocusChange: (on) {
                if (on) {
                  HardwareKeyboard.instance.addHandler(_keyHandler);
                } else {
                  HardwareKeyboard.instance.removeHandler(_keyHandler);
                }
              },
              child: Container(
                  width: 512,
                  height: 480,
                  color: Colors.black,
                  child: StreamBuilder<ui.Image>(
                      stream: controller.imageStream.asyncMap(renderVideo),
                      builder: (ctx, snapshot) =>
                          RawImage(image: snapshot.data, scale: 0.5)))),

          // debug control
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            const SizedBox(width: 30.0),
            StreamBuilder<double>(
                stream: controller.fpsStream,
                builder: (ctx, snapshot) =>
                    Text("${(snapshot.data ?? 0.0).toStringAsFixed(2)} fps")),
          ]),

          // debug view
          StreamBuilder<String>(
              stream: controller.debugStream,
              builder: (ctx, snapshot) =>
                  Text(snapshot.data ?? "", style: debugStyle)),
        ],
      ),
    );
  }
}
