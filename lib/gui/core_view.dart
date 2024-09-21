// Dart imports:
import 'dart:ui' as ui;

// Flutter imports:
import 'package:flutter/material.dart';

// Project imports:
import '../spec.dart';
import 'core_controller.dart';
import 'virtual_pad.dart';

class CoreView extends StatefulWidget {
  final CoreController controller;

  const CoreView({super.key, required this.controller});

  @override
  State<CoreView> createState() => _NewViewState();
}

class _NewViewState extends State<CoreView> {
  final imageNotifier = ValueNotifier<ui.Image?>(null);

  static const maskLinesTop = 0;
  static const maskLinesBottom = 0;
  static const height = Spec.height - maskLinesTop - maskLinesBottom;
  static const width = Spec.width;

  @override
  void initState() {
    super.initState();
    widget.controller.imageStream.listen((buf) => ui.decodeImageFromPixels(
        buf.sublist(4 * width * maskLinesTop,
            4 * width * (Spec.height - maskLinesBottom)),
        width,
        height,
        ui.PixelFormat.rgba8888,
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
            width: width * 2,
            height: height * 2,
            color: Colors.black,
            child: ValueListenableBuilder(
              valueListenable: imageNotifier,
              builder: (context, image, child) {
                return image != null
                    ? RawImage(
                        image: image,
                        scale: 0.5,
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
