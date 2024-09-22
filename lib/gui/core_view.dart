// Dart imports:
import 'dart:ui' as ui;

// Flutter imports:
import 'package:flutter/material.dart';

import 'config.dart';
import 'core_controller.dart';
import 'virtual_pad.dart';

class CoreView extends StatefulWidget {
  final CoreController controller;

  const CoreView({super.key, required this.controller});

  @override
  State<CoreView> createState() => _CoreViewState();
}

class _CoreViewState extends State<CoreView> {
  final imageNotifier = ValueNotifier<ui.Image?>(null);

  static final config = Config();

  @override
  void initState() {
    super.initState();
    widget.controller.imageStream.listen((buf) => ui.decodeImageFromPixels(
        buf.buffer,
        buf.width,
        buf.height,
        ui.PixelFormat.rgba8888,
        targetWidth: config.imageWidth,
        targetHeight: config.imageHeight,
        allowUpscaling: true,
        (image) => imageNotifier.value = image));
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
          Container(
            width: config.imageWidth * 1,
            height: config.imageHeight * 1,
            color: Colors.black,
            child: ValueListenableBuilder(
              valueListenable: imageNotifier,
              builder: (context, image, child) {
                return image != null
                    ? RawImage(
                        image: image,
                      )
                    : const FittedBox();
              },
            ),
          ),

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
