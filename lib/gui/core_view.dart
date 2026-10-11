import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:fnesemu_core/app_api.dart';
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
          const headerHeight = 64.0;
          final portrait = constraints.maxHeight > constraints.maxWidth;
          return Stack(children: [
            Positioned.fill(
              child: LayoutBuilder(
                  builder: (context, gameConstraints) => Align(
                        alignment: Alignment.topCenter,
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
                            final gameHeight = width / aspect;
                            final headerFits = portrait &&
                                gameConstraints.maxHeight - gameHeight >=
                                    headerHeight +
                                        DirectionPad.diameter +
                                        inset * 2;
                            return Padding(
                                padding: EdgeInsets.only(
                                    top: headerFits ? headerHeight : 0),
                                child: SizedBox(
                                  key: const ValueKey('game-viewport'),
                                  width: width,
                                  height: width / aspect,
                                  child: imageListener(
                                      width: width,
                                      height: width / aspect,
                                      notifier: widget.container.imageNotifier),
                                ));
                          },
                        ),
                      )),
            ),
            Positioned(
                left: inset,
                top: portrait ? null : 0,
                bottom: portrait ? inset : 0,
                child: Align(
                    widthFactor: 1,
                    heightFactor: 1,
                    alignment: Alignment.centerLeft,
                    child: DirectionPad(input: _input))),
            Positioned(
                right: inset,
                top: portrait ? null : 0,
                bottom: portrait ? inset : 0,
                child: Align(
                    widthFactor: 1,
                    heightFactor: 1,
                    alignment: Alignment.centerRight,
                    child: VirtualPadWidget(
                        controller: widget.controller, input: _input))),
          ]);
        }),
      );
}
