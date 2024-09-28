// Dart imports:
import 'dart:async';
import 'dart:ui' as ui;

// Flutter imports:
import 'package:flutter/material.dart';
import 'package:fnesemu/gui/stream_image.dart';

import '../core/core_controller.dart';
import 'config.dart';
import 'virtual_pad.dart';

class CoreView extends StatefulWidget {
  final CoreController controller;

  const CoreView({super.key, required this.controller});

  @override
  State<CoreView> createState() => _CoreViewState();
}

class _CoreViewState extends State<CoreView> {
  final imageStream = StreamController<ui.Image>();

  static final config = Config();

  @override
  void initState() {
    super.initState();
    widget.controller.imageStream.listen((buf) => ui.decodeImageFromPixels(
        buf.buffer,
        buf.width,
        buf.height,
        ui.PixelFormat.rgba8888,
        (image) => imageStream.sink.add(image)));
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // main view
          StreamImageWidget(
              imageStream: imageStream.stream,
              width: config.imageWidth * 1,
              height: config.imageHeight * 1),

          // virtual pad
          VirtualPadWidget(controller: widget.controller),

          // debug control
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            StreamBuilder<double>(
                stream: widget.controller.fpsStream,
                builder: (ctx, snapshot) =>
                    Text("${((snapshot.data ?? 0.0)).round()} fps")),
          ]),
        ],
      ),
    );
  }
}
