import 'package:flutter/material.dart';

import 'package:fnesemu_core/app_api.dart';
import 'direction_pad.dart';
import 'pad_input.dart';

/// A touch / mouse stick that reports two axes in -1.0..1.0.
/// Fixed logical-pixel size, 0.8 times the [DirectionPad].
class AnalogStick extends StatefulWidget {
  static const diameter = DirectionPad.diameter * 0.8;
  static const radius = diameter / 2 - 4;

  /// Fraction of the radius that reads as neutral.
  static const deadZone = 0.3;
  static const dotRadius = 7.0;

  final PadInput input;
  final PadAxis axisX;
  final PadAxis axisY;
  final String label;

  const AnalogStick(
      {super.key,
      required this.input,
      required this.axisX,
      required this.axisY,
      this.label = 'Analog stick'});

  /// Returns the touch position clamped into the circle, relative to the
  /// center.
  static Offset clamped(Offset position) {
    final offset = position - const Offset(diameter / 2, diameter / 2);
    return offset.distance <= radius
        ? offset
        : offset / offset.distance * radius;
  }

  /// Returns (x, y) in -1.0..1.0 for an [offset] from the center. The dead
  /// zone reads 0 and the magnitude grows linearly to 1.0 at the edge. The
  /// direction is kept, so a diagonal never exceeds 1.0 in length.
  static (double, double) valueOf(Offset offset) {
    final distance = offset.distance;
    if (distance == 0) return (0, 0);
    final magnitude =
        ((distance - radius * deadZone) / (radius * (1 - deadZone)))
            .clamp(0.0, 1.0);
    return (offset.dx / distance * magnitude, offset.dy / distance * magnitude);
  }

  @override
  State<AnalogStick> createState() => _AnalogStickState();
}

class _AnalogStickState extends State<AnalogStick> {
  final _source = Object();
  int? _pointer;
  int? _generation;
  Offset? _dot;

  void _update(Offset position) {
    final offset = AnalogStick.clamped(position);
    final (x, y) = AnalogStick.valueOf(offset);
    setState(() => _dot = offset);
    widget.input.setAxisSource(_source, {widget.axisX: x, widget.axisY: y});
  }

  void _release() {
    _pointer = null;
    widget.input.setAxisSource(_source, {});
    if (mounted) setState(() => _dot = null);
  }

  @override
  void deactivate() {
    _pointer = null;
    widget.input.setAxisSource(_source, {});
    super.deactivate();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: AnalogStick.diameter,
        child: Semantics(
          label: widget.label,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) {
              if (_pointer != null && _generation == widget.input.generation) {
                return;
              }
              final offset = event.localPosition -
                  const Offset(
                      AnalogStick.diameter / 2, AnalogStick.diameter / 2);
              if (!widget.input.enabled ||
                  offset.distance > AnalogStick.radius) {
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
            child: CustomPaint(
              painter: AnalogStickPainter(
                  colors: Theme.of(context).colorScheme, dot: _dot),
            ),
          ),
        ),
      );
}

class AnalogStickPainter extends CustomPainter {
  final ColorScheme colors;

  /// The touched position relative to the center, null while not touched.
  final Offset? dot;
  const AnalogStickPainter({required this.colors, required this.dot});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    canvas.drawCircle(center, AnalogStick.radius,
        Paint()..color = colors.surfaceContainerHigh.withValues(alpha: 0.92));
    final outline = Paint()
      ..color = colors.outline
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawCircle(center, AnalogStick.radius, outline);
    canvas.drawCircle(center, AnalogStick.radius * AnalogStick.deadZone,
        outline..color = colors.outline.withValues(alpha: 0.5));
    final touched = dot;
    if (touched != null) {
      canvas.drawCircle(center + touched, AnalogStick.dotRadius,
          Paint()..color = colors.primary);
    }
  }

  @override
  bool shouldRepaint(AnalogStickPainter oldDelegate) =>
      dot != oldDelegate.dot || colors != oldDelegate.colors;
}
