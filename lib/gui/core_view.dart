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
          ListenableBuilder(
              listenable: Listenable.merge([
                widget.container.displayWidthNotifier,
                widget.container.displayHeightNotifier,
              ]),
              builder: (context, child) => imageListener(
                  width: config.screenWidth,
                  height: config.screenWidth *
                      widget.container.displayHeightNotifier.value /
                      widget.container.displayWidthNotifier.value,
                  notifier: widget.container.imageNotifier)),

          // virtual pad
          VirtualPadWidget(
              controller: widget.controller, width: config.screenWidth),
        ],
      ),
    );
  }
}
