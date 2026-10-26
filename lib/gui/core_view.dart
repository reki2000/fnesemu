import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:fnesemu_core/app_api.dart';
import 'analog_stick.dart';
import 'direction_pad.dart';
import 'pad_input.dart';
import 'ticker_image.dart';
import 'virtual_pad.dart';

class CoreView extends StatefulWidget {
  final CoreController controller;
  final ImageContainer container;
  final PadInput? input;
  final bool? portrait;
  final bool showPad;
  final double? maxImageWidth;

  const CoreView(
      {super.key,
      required this.controller,
      required this.container,
      this.input,
      this.portrait,
      this.showPad = true,
      this.maxImageWidth});

  @override
  State<CoreView> createState() => _CoreViewState();
}

class _CoreViewState extends State<CoreView> {
  late final PadInput _input = widget.input ?? PadInput();

  @override
  void initState() {
    super.initState();
    if (widget.input == null) widget.controller.input = _input;
  }

  @override
  void dispose() {
    if (widget.input == null) {
      widget.controller.input = const NoPadSource();
      _input.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: LayoutBuilder(builder: (context, constraints) {
          const inset = 12.0;
          const stickGap = 12.0;
          final axes = widget.controller.axes;
          final hasLeftStick =
              axes.contains(PadAxis.leftX) && axes.contains(PadAxis.leftY);
          final hasRightStick =
              axes.contains(PadAxis.rightX) && axes.contains(PadAxis.rightY);
          final hasStick = hasLeftStick || hasRightStick;
          const headerHeight = 64.0;
          final portrait =
              widget.portrait ?? constraints.maxHeight > constraints.maxWidth;
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
                            final width = math.min(
                                math.min(gameConstraints.maxWidth,
                                    widget.maxImageWidth ?? double.infinity),
                                gameConstraints.maxHeight * aspect);
                            final gameHeight = width / aspect;
                            final headerFits = portrait &&
                                gameConstraints.maxHeight - gameHeight >=
                                    headerHeight +
                                        DirectionPad.diameter +
                                        (hasStick
                                            ? AnalogStick.diameter + stickGap
                                            : 0) +
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
            if (widget.showPad)
              Positioned(
                  left: inset,
                  top: portrait ? null : 0,
                  bottom: portrait ? inset : 0,
                  child: Align(
                      widthFactor: 1,
                      heightFactor: 1,
                      alignment: Alignment.centerLeft,
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          spacing: stickGap,
                          children: [
                            if (hasLeftStick)
                              AnalogStick(
                                  key: const ValueKey('left-stick'),
                                  input: _input,
                                  axisX: PadAxis.leftX,
                                  axisY: PadAxis.leftY,
                                  label: 'Left analog stick'),
                            DirectionPad(input: _input),
                          ]))),
            if (widget.showPad)
              Positioned(
                  right: inset,
                  top: portrait ? null : 0,
                  bottom: portrait ? inset : 0,
                  child: Align(
                      widthFactor: 1,
                      heightFactor: 1,
                      alignment: Alignment.centerRight,
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          spacing: stickGap,
                          children: [
                            if (hasRightStick)
                              AnalogStick(
                                  key: const ValueKey('right-stick'),
                                  input: _input,
                                  axisX: PadAxis.rightX,
                                  axisY: PadAxis.rightY,
                                  label: 'Right analog stick'),
                            VirtualPadWidget(
                                controller: widget.controller, input: _input),
                          ]))),
          ]);
        }),
      );
}
