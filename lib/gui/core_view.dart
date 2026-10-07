import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/core_controller.dart';
import 'direction_pad.dart';
import 'pad_input.dart';
import 'ticker_image.dart';
import 'virtual_pad.dart';

class CoreView extends StatefulWidget {
  final CoreController controller;
  final ImageContainer container;
  final PadInput? input;

  const CoreView(
      {super.key,
      required this.controller,
      required this.container,
      this.input});

  @override
  State<CoreView> createState() => _CoreViewState();
}

class _CoreViewState extends State<CoreView> {
  late final PadInput _input = widget.input ??
      PadInput(
          onDown: (button) => widget.controller.padDown(0, button),
          onUp: (button) => widget.controller.padUp(0, button));

  @override
  void dispose() {
    if (widget.input == null) _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: LayoutBuilder(builder: (context, constraints) {
          const inset = 12.0;
          return Stack(children: [
            Positioned.fill(
              child: LayoutBuilder(
                  builder: (context, gameConstraints) => Center(
                        child: ListenableBuilder(
                          listenable: Listenable.merge([
                            widget.container.displayWidthNotifier,
                            widget.container.displayHeightNotifier,
                          ]),
                          builder: (context, _) {
                            final aspect = widget
                                    .container.displayWidthNotifier.value /
                                widget.container.displayHeightNotifier.value;
                            final width = math.min(gameConstraints.maxWidth,
                                gameConstraints.maxHeight * aspect);
                            return SizedBox(
                              key: const ValueKey('game-viewport'),
                              width: width,
                              height: width / aspect,
                              child: imageListener(
                                  width: width,
                                  height: width / aspect,
                                  notifier: widget.container.imageNotifier),
                            );
                          },
                        ),
                      )),
            ),
            Positioned(
                left: inset, bottom: inset, child: DirectionPad(input: _input)),
            Positioned(
                right: inset,
                bottom: inset,
                child: VirtualPadWidget(
                    controller: widget.controller, input: _input)),
          ]);
        }),
      );
}
