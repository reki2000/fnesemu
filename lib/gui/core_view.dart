// Dart imports:

// Flutter imports:
import 'package:flutter/material.dart';
import 'package:fnesemu/gui/ticker_image.dart';

import '../core/core_controller.dart';
import 'config.dart';
import 'virtual_pad.dart';

class CoreView extends StatefulWidget {
  final CoreController controller;
  final ImageContainer container;

  const CoreView(
      {super.key, required this.controller, required this.container});

  @override
  State<CoreView> createState() => _CoreViewState();
}

class _CoreViewState extends State<CoreView> {
  static final config = Config();

  @override
  void initState() {
    super.initState();
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
          ValueListenableBuilder<int>(
              valueListenable: widget.container.displayWidthNotifier,
              builder: (context, width, child) => TickerImage(
                  width: width * config.zoom,
                  height: widget.container.displayHeight * config.zoom,
                  container: widget.container)),

          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            // debug control
            StreamBuilder<double>(
                stream: widget.controller.fpsStream,
                builder: (ctx, snapshot) => Text(
                    ((snapshot.data ?? 0.0)).toStringAsFixed(1).padLeft(4))),
            // virtual pad
            VirtualPadWidget(controller: widget.controller),
          ]),
        ],
      ),
    );
  }
}
