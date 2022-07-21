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

Widget keyListener(
    {required BuildContext context,
    required Widget child,
    required FocusNode focusNode,
    required void Function(PadButton) keyDown,
    required void Function(PadButton) keyUp}) {
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
              keyDown(entry.value);
              break;
            }
          }
          break;
        case RawKeyUpEvent:
          for (final entry in keys.entries) {
            if (entry.key == e.data.logicalKey) {
              keyUp(entry.value);
              break;
            }
          }
          break;
      }
    },
  );
}

class NesWidget extends StatefulWidget {
  final Nes emulator;
  const NesWidget({Key? key, required this.emulator}) : super(key: key);

  @override
  State<NesWidget> createState() => _NesWidgetState();
}

class _NesWidgetState extends State<NesWidget> {
  final _focusNode = FocusNode();
  bool _showDebugView = false;
  ui.Image? screenImage;

  @override
  void initState() {
    super.initState();
    widget.emulator.renderVideo = renderVideo;
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
    _focusNode.requestFocus();
    return RepaintBoundary(
      child: Column(
        children: [
          keyListener(
              context: ctx,
              focusNode: _focusNode,
              keyDown: widget.emulator.keyDown,
              keyUp: widget.emulator.keyUp,
              child: Container(
                width: 512,
                height: 480,
                color: Colors.black,
                child: RawImage(image: screenImage, scale: 0.5),
              )),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Checkbox(
                value: _showDebugView,
                onChanged: (on) => setState(() {
                      _showDebugView = on ?? false;
                    })),
            const Text("Debug Info"),
            const SizedBox(width: 30.0),
            Text("${widget.emulator.fps.toStringAsFixed(2)} fps"),
          ]),
          if (_showDebugView)
            Text(
                widget.emulator.dump(
                  showZeroPage: true,
                  showStack: true,
                  showApu: true,
                ),
                style: debugStyle),
        ],
      ),
    );
  }
}
