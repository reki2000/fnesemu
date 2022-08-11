// Dart imports:
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

// Flutter imports:
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Project imports:
import '../cpu/joypad.dart';
import '../cpu/nes.dart';
import '../styles.dart';

class NesWidget extends StatefulWidget {
  final Nes emulator;
  const NesWidget({Key? key, required this.emulator}) : super(key: key);

  @override
  State<NesWidget> createState() => _NesWidgetState();
}

class _NesWidgetState extends State<NesWidget> {
  final _imageStream = StreamController<ui.Image>();
  final _fpsStream = StreamController<double>();
  final _debugStream = StreamController<String>();

  bool _showDebugView = false;

  @override
  void initState() {
    super.initState();
    widget.emulator.renderVideo = renderVideo;
  }

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
            widget.emulator.keyDown(entry.value);
            break;
          case KeyUpEvent:
            widget.emulator.keyUp(entry.value);
            break;
        }
        return true;
      }
    }
    return false;
  }

  @override
  void dispose() {
    _imageStream.close();
    _fpsStream.close();
    _debugStream.close();
    super.dispose();
  }

  Future<void> renderVideo(Uint8List buf) async {
    _fpsStream.add(widget.emulator.fps);

    if (_showDebugView) {
      showDebug();
    }
    ui.decodeImageFromPixels(
        buf, 256, 240, ui.PixelFormat.rgba8888, (img) => _imageStream.add(img));
  }

  void showDebug() {
    _debugStream.add(widget.emulator.dump(
      showZeroPage: true,
      showStack: true,
      showApu: true,
    ));
  }

  @override
  Widget build(BuildContext ctx) {
    return RepaintBoundary(
      child: Column(
        children: [
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
                      stream: _imageStream.stream,
                      builder: (ctx, snapshot) =>
                          RawImage(image: snapshot.data, scale: 0.5)))),

          // debug control
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Checkbox(
                value: _showDebugView,
                onChanged: (on) => setState(() {
                      _showDebugView = on ?? false;
                      if (_showDebugView) {
                        showDebug();
                      } else {
                        _debugStream.add("");
                      }
                    })),
            const Text("Debug Info"),
            const SizedBox(width: 30.0),
            StreamBuilder<double>(
                stream: _fpsStream.stream,
                builder: (ctx, snapshot) =>
                    Text("${(snapshot.data ?? 0.0).toStringAsFixed(2)} fps")),
          ]),

          // debug view
          StreamBuilder<String>(
              stream: _debugStream.stream,
              builder: (ctx, snapshot) =>
                  Text(snapshot.data ?? "", style: debugStyle)),
        ],
      ),
    );
  }
}
