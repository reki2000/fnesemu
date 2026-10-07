import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/pad_button.dart';
import 'pad_input.dart';

const directionButtons = <Set<PadButton>>[
  {PadButton.up},
  {PadButton.up, PadButton.right},
  {PadButton.right},
  {PadButton.right, PadButton.down},
  {PadButton.down},
  {PadButton.down, PadButton.left},
  {PadButton.left},
  {PadButton.left, PadButton.up},
];

/// Fixed logical-pixel size on every platform and window size.
class DirectionPad extends StatefulWidget {
  static const diameter = 160.0;
  static const innerRadius = 32.0;
  static const outerRadius = diameter / 2 - 4;
  final PadInput input;

  const DirectionPad({super.key, required this.input});

  static int? sectorAt(Offset position) {
    final offset = position - const Offset(diameter / 2, diameter / 2);
    if (offset.distance < innerRadius || offset.distance > outerRadius) {
      return null;
    }
    final clockwise = math.atan2(offset.dx, -offset.dy);
    return ((clockwise + math.pi / 8) / (math.pi / 4)).floor() % 8;
  }

  static int? activeSector(Set<PadButton> pressed) {
    final x = (pressed.contains(PadButton.right) ? 1 : 0) -
        (pressed.contains(PadButton.left) ? 1 : 0);
    final y = (pressed.contains(PadButton.down) ? 1 : 0) -
        (pressed.contains(PadButton.up) ? 1 : 0);
    if (x == 0 && y == 0) return null;
    return ((math.atan2(x, -y) + math.pi / 8) / (math.pi / 4)).floor() % 8;
  }

  @override
  State<DirectionPad> createState() => _DirectionPadState();
}

class _DirectionPadState extends State<DirectionPad> {
  final _source = Object();
  int? _pointer;
  int? _generation;

  void _update(Offset position) {
    final sector = DirectionPad.sectorAt(position);
    widget.input
        .setSource(_source, sector == null ? {} : directionButtons[sector]);
  }

  void _release() {
    _pointer = null;
    widget.input.setSource(_source, {});
  }

  @override
  void deactivate() {
    _release();
    super.deactivate();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: DirectionPad.diameter,
        child: Semantics(
          label: 'Eight-direction pad',
          child: Listener(
            onPointerDown: (event) {
              if (_pointer != null && _generation == widget.input.generation) {
                return;
              }
              if (!widget.input.enabled ||
                  DirectionPad.sectorAt(event.localPosition) == null) {
                return;
              }
              _pointer = event.pointer;
              _generation = widget.input.generation;
              _update(event.localPosition);
            },
            onPointerMove: (event) {
              if (_pointer == event.pointer &&
                  _generation == widget.input.generation) {
                _update(event.localPosition);
              }
            },
            onPointerUp: (event) {
              if (_pointer == event.pointer) _release();
            },
            onPointerCancel: (event) {
              if (_pointer == event.pointer) _release();
            },
            child: ListenableBuilder(
              listenable: widget.input,
              builder: (context, _) => CustomPaint(
                painter: DirectionPadPainter(
                    colors: Theme.of(context).colorScheme,
                    activeSector:
                        DirectionPad.activeSector(widget.input.pressed)),
              ),
            ),
          ),
        ),
      );
}

class DirectionPadPainter extends CustomPainter {
  final ColorScheme colors;
  final int? activeSector;
  const DirectionPadPainter({required this.colors, required this.activeSector});
  static const _arrows = ['↑', '↗', '→', '↘', '↓', '↙', '←', '↖'];

  @override
  bool? hitTest(Offset position) => DirectionPad.sectorAt(position) != null;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final outer =
        Rect.fromCircle(center: center, radius: DirectionPad.outerRadius);
    final inner =
        Rect.fromCircle(center: center, radius: DirectionPad.innerRadius);
    const sweep = math.pi / 4;
    for (var sector = 0; sector < 8; sector++) {
      final start = -math.pi / 2 - math.pi / 8 + sector * sweep;
      final path = Path()
        ..arcTo(outer, start, sweep, true)
        ..arcTo(inner, start + sweep, -sweep, false)
        ..close();
      final active = sector == activeSector;
      canvas.drawPath(
          path,
          Paint()
            ..color = active
                ? colors.primary
                : colors.surfaceContainerHigh.withValues(alpha: 0.92));
      canvas.drawPath(
          path,
          Paint()
            ..color = colors.outline
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1);
      final angle = -math.pi / 2 + sector * sweep;
      final label = TextPainter(
        text: TextSpan(
            text: '$sector ${_arrows[sector]}',
            style: TextStyle(
                color: active ? colors.onPrimary : colors.onSurface,
                fontSize: 14,
                fontWeight: FontWeight.w600)),
        textDirection: TextDirection.ltr,
      )..layout();
      final location = center + Offset(math.cos(angle), math.sin(angle)) * 54;
      label.paint(canvas, location - Offset(label.width / 2, label.height / 2));
    }
  }

  @override
  bool shouldRepaint(DirectionPadPainter oldDelegate) =>
      activeSector != oldDelegate.activeSector || colors != oldDelegate.colors;
}
