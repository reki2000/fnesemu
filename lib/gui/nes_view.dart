// Dart imports:
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

// Flutter imports:
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Project imports:
import '../styles.dart';
import 'nes_controller.dart';

class NesView extends StatefulWidget {
  final NesController controller;
  final FocusNode focusNode;

  const NesView({Key? key, required this.controller, required this.focusNode})
      : super(key: key);

  @override
  _NewViewState createState() => _NewViewState();
}

class _NewViewState extends State<NesView> {
  late final Stream<ui.Image> _imageStream;

  @override
  void initState() {
    super.initState();
    _imageStream = widget.controller.imageStream.asyncMap(renderVideo);
  }

  @override
  void dispose() {
    super.dispose();
  }

  static final keys = {
    PhysicalKeyboardKey.arrowDown: NesPadButton.down,
    PhysicalKeyboardKey.arrowUp: NesPadButton.up,
    PhysicalKeyboardKey.arrowLeft: NesPadButton.left,
    PhysicalKeyboardKey.arrowRight: NesPadButton.right,
    PhysicalKeyboardKey.keyX: NesPadButton.a,
    PhysicalKeyboardKey.keyZ: NesPadButton.b,
    PhysicalKeyboardKey.keyA: NesPadButton.select,
    PhysicalKeyboardKey.keyS: NesPadButton.start,
  };

  bool _keyHandler(KeyEvent e) {
    for (final entry in keys.entries) {
      if (entry.key == e.physicalKey) {
        switch (e.runtimeType) {
          case KeyDownEvent:
            widget.controller.padDown(entry.value);
            break;
          case KeyUpEvent:
            widget.controller.padUp(entry.value);
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
    return RepaintBoundary(
      child: Column(
        children: [
          // main view
          Focus(
              focusNode: widget.focusNode,
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
                      stream: _imageStream,
                      builder: (ctx, snapshot) =>
                          RawImage(image: snapshot.data, scale: 0.5)))),

          // debug control
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            const SizedBox(width: 30.0),
            StreamBuilder<double>(
                stream: widget.controller.fpsStream,
                builder: (ctx, snapshot) =>
                    Text("${(snapshot.data ?? 0.0).toStringAsFixed(2)} fps")),
          ]),

          // debug view
          StreamBuilder<String>(
              stream: widget.controller.debugStream,
              builder: (ctx, snapshot) =>
                  Text(snapshot.data ?? "", style: debugStyle)),
        ],
      ),
    );
  }
}
