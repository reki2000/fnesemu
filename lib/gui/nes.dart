// Dart imports:
import 'dart:typed_data';
import 'dart:ui' as ui;

// Flutter imports:
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Package imports:
import 'package:google_fonts/google_fonts.dart';

// Project imports:
import '../cpu/joypad.dart';
import '../cpu/nes.dart';

final nes = Nes();

final debugStyle = GoogleFonts.robotoMono(fontSize: 12);

Widget keyListener(
    {required BuildContext context,
    required Widget child,
    required FocusNode focusNode}) {
  final keys = <LogicalKeyboardKey, PadButton>{
    LogicalKeyboardKey.arrowDown: PadButton.down,
    LogicalKeyboardKey.arrowUp: PadButton.up,
    LogicalKeyboardKey.arrowLeft: PadButton.left,
    LogicalKeyboardKey.arrowRight: PadButton.right,
    LogicalKeyboardKey.keyX: PadButton.a,
    LogicalKeyboardKey.keyZ: PadButton.b,
    LogicalKeyboardKey.keyA: PadButton.select,
    LogicalKeyboardKey.keyS: PadButton.start,
  };

  return RawKeyboardListener(
    child: child,
    focusNode: focusNode,
    onKey: (e) {
      switch (e.runtimeType) {
        case RawKeyDownEvent:
          for (final entry in keys.entries) {
            if (entry.key == e.data.logicalKey) {
              nes.bus.joypad.keyDown(entry.value);
              break;
            }
          }
          break;
        case RawKeyUpEvent:
          for (final entry in keys.entries) {
            if (entry.key == e.data.logicalKey) {
              nes.bus.joypad.keyUp(entry.value);
              break;
            }
          }
          break;
      }
    },
  );
}

class NesWidget extends StatefulWidget {
  const NesWidget({Key? key}) : super(key: key);

  @override
  State<NesWidget> createState() => _NesWidgetState();
}

class _NesWidgetState extends State<NesWidget> {
  final _focusNode = FocusNode();
  bool _showDebugView = false;

  @override
  void initState() {
    super.initState();
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext ctx) {
    return Column(
      children: [
        keyListener(
          context: ctx,
          focusNode: _focusNode,
          child: Container(
              width: 512,
              height: 480,
              color: Colors.black,
              child: _NesImageWidget()),
        ),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Checkbox(
              value: _showDebugView,
              onChanged: (on) => setState(() {
                    _showDebugView = on ?? false;
                  })),
          const Text("Debug Info"),
          const SizedBox(width: 30.0),
          Text("${nes.fps.toStringAsFixed(2)} fps"),
        ]),
        if (_showDebugView)
          Text(
              nes.dump(
                showZeroPage: true,
                showStack: true,
                showApu: true,
              ),
              style: debugStyle),
      ],
    );
  }
}

class _NesImageWidget extends StatefulWidget {
  @override
  State<_NesImageWidget> createState() => _NesImageWidgetState();
}

class _NesImageWidgetState extends State<_NesImageWidget> {
  ui.Image? screenImage;

  @override
  void initState() {
    super.initState();
    nes.renderVideo = renderVideo;
  }

  Future<void> renderVideo(Uint8List buf) async {
    ui.decodeImageFromPixels(
        buf, 256, 240, ui.PixelFormat.rgba8888, _updateImage);
  }

  void _updateImage(ui.Image image) {
    setState(() {
      screenImage?.dispose();
      screenImage = image;
    });
  }

  @override
  Widget build(BuildContext ctx) {
    return RawImage(image: screenImage, scale: 0.5);
  }
}
