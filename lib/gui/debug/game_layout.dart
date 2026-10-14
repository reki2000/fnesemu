import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The left pane width is a pixel preference, independent of window size.
/// Images remain capped at 640 logical pixels even if the pane is wider.
class DebugGameLayout extends StatefulWidget {
  final double gameAspect;
  final bool enabled;
  final ValueNotifier<double?>? paneWidth;
  final Widget Function(bool portrait, bool showPad, double? maxImageWidth)
      game;
  final Widget panel, dump;
  const DebugGameLayout(
      {super.key,
      required this.gameAspect,
      required this.game,
      required this.panel,
      required this.dump,
      this.enabled = true,
      this.paneWidth});
  @override
  State<DebugGameLayout> createState() => _DebugGameLayoutState();
}

class _DebugGameLayoutState extends State<DebugGameLayout> {
  late final _width = widget.paneWidth ?? ValueNotifier<double?>(null);
  @override
  void dispose() {
    if (widget.paneWidth == null) _width.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, bounds) {
        final portrait = bounds.maxHeight > bounds.maxWidth;
        if (!widget.enabled || portrait) {
          return widget.game(portrait, true, null);
        }
        return ValueListenableBuilder<double?>(
            valueListenable: _width,
            builder: (context, preference, _) {
              final width = preference ??
                  math.min(640.0, math.max(128.0, bounds.maxWidth - 280));
              if (preference == null) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && _width.value == null) _width.value = width;
                });
              }
              final height = math.max(240.0, bounds.maxHeight);
              final imageHeight = math.min(
                  math.min(width, 640) / widget.gameAspect, height - 100);
              final panelWidth = math.max(220.0, bounds.maxWidth - width - 8);
              return SingleChildScrollView(
                  child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                                key: const ValueKey('debug-game-area'),
                                width: width,
                                height: height,
                                child: Column(children: [
                                  SizedBox(
                                      height: imageHeight,
                                      child: widget.game(false, false, 640)),
                                  Expanded(
                                      child: Padding(
                                          padding: const EdgeInsets.all(8),
                                          child: widget.dump)),
                                ])),
                            MouseRegion(
                                cursor: SystemMouseCursors.resizeLeftRight,
                                child: GestureDetector(
                                    key: const ValueKey('debug-divider'),
                                    behavior: HitTestBehavior.opaque,
                                    onHorizontalDragUpdate: (event) =>
                                        _width.value = math.max(
                                            128.0,
                                            (_width.value ?? width) +
                                                event.delta.dx),
                                    child: SizedBox(
                                        width: 8,
                                        height: height,
                                        child: Center(
                                            child: Container(
                                                width: 2,
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .outlineVariant))))),
                            SizedBox(
                                key: const ValueKey('debug-tabs-area'),
                                width: panelWidth,
                                height: height,
                                child: widget.panel),
                          ])));
            });
      });
}
