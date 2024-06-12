// Dart imports:
import 'dart:typed_data';
import 'dart:ui' as ui;

// Flutter imports:
import 'package:flutter/material.dart';

// Project imports:
import '../spec.dart';
import '../styles.dart';
import 'nes_controller.dart';
import 'virtual_pad.dart';

class NesView extends StatefulWidget {
  final NesController controller;

  const NesView({super.key, required this.controller});

  @override
  State<NesView> createState() => _NewViewState();
}

class _NewViewState extends State<NesView> {
  final _imageNotifier = ValueNotifier<ui.Image?>(null);

  static const _maskLinesTop = 8;
  static const _maskLinesBottom = 8;
  static const _height = Spec.height - _maskLinesTop - _maskLinesBottom;
  static const _width = Spec.width;

  @override
  void initState() {
    super.initState();
    widget.controller.imageStream.listen(
        (buf) => _renderVideo(buf, (image) => _imageNotifier.value = image));
  }

  @override
  void dispose() {
    super.dispose();
  }

  void _renderVideo(Uint8List buf, void Function(ui.Image) callback) {
    ui.decodeImageFromPixels(
        buf.sublist(4 * _width * _maskLinesTop,
            4 * _width * (Spec.height - _maskLinesBottom)),
        _width,
        _height,
        ui.PixelFormat.rgba8888,
        callback);
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // main view
          Container(
              width: _width * 2,
              height: _height * 2,
              color: Colors.black,
              child: Container(
                  width: _width.toDouble(),
                  height: _height.toDouble(),
                  transform: (Matrix4.identity() * 2.0),
                  child: CustomPaint(painter: ImagePainter(_imageNotifier)))),

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

class ImagePainter extends CustomPainter {
  static final _paint = Paint();
  static const _offset = Offset(0.0, 0.0);

  final ValueNotifier<ui.Image?> notifier;

  ImagePainter(this.notifier) : super(repaint: notifier);

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    if (notifier.value != null) {
      canvas.save();
      canvas.drawImage(notifier.value!, _offset, _paint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return true;
  }
}
