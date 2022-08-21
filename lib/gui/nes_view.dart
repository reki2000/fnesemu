// Dart imports:
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

// Flutter imports:
import 'package:flutter/material.dart';

// Project imports:
import '../styles.dart';
import 'nes_controller.dart';
import 'virtual_pad.dart';

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
    _imageStream = widget.controller.imageStream.asyncMap(_renderVideo);
  }

  @override
  void dispose() {
    super.dispose();
  }

  static const maskLinesTop = 8;
  static const maskLinesBottom = 8;

  Future<ui.Image> _renderVideo(Uint8List buf) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
        buf.sublist(4 * 256 * maskLinesTop, 4 * 256 * (240 - maskLinesBottom)),
        256,
        240 - maskLinesTop - maskLinesBottom,
        ui.PixelFormat.rgba8888,
        completer.complete);
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
              child: Container(
                  width: 256 * 2,
                  height: (240 - maskLinesTop - maskLinesBottom) * 2,
                  color: Colors.black,
                  child: StreamBuilder<ui.Image>(
                      stream: _imageStream,
                      builder: (ctx, snapshot) =>
                          RawImage(image: snapshot.data, scale: 0.5)))),

          // virtual pad
          VirtualPadWidget(controller: widget.controller),

          // debug control
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
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
