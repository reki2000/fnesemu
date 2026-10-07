// Dart imports:

// Flutter imports:
import 'dart:math' as math;

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
      child: LayoutBuilder(builder: (context, constraints) {
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : config.screenWidth;
        final availableHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : config.screenWidth + 56;
        final padHeight = math.min(56.0, availableHeight);
        return Column(
          children: [
            Expanded(
                child: Center(
                    child: ListenableBuilder(
                        listenable: Listenable.merge([
                          widget.container.displayWidthNotifier,
                          widget.container.displayHeightNotifier,
                        ]),
                        builder: (context, child) {
                          final aspect =
                              widget.container.displayWidthNotifier.value /
                                  widget.container.displayHeightNotifier.value;
                          final width = math.min(
                              availableWidth,
                              math.max(0.0, availableHeight - padHeight) *
                                  aspect);
                          return imageListener(
                              width: width,
                              height: width / aspect,
                              notifier: widget.container.imageNotifier);
                        }))),

            // virtual pad
            SizedBox(
                height: padHeight,
                child: VirtualPadWidget(
                    controller: widget.controller, width: availableWidth)),
          ],
        );
      }),
    );
  }
}
