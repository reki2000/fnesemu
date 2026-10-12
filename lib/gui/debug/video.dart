import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:fnesemu_core/app_api.dart';

Color _rgba(int value) => Color.fromARGB(
    value >> 24 & 255, value & 255, value >> 8 & 255, value >> 16 & 255);

/// Core-owned native pixels and geometry; the GUI only paints them.
class DebugVideoImages extends StatelessWidget {
  final DebugState state;
  final double scale;
  final ValueChanged<VideoHover>? onHover;
  final VoidCallback? onExit;
  const DebugVideoImages(
      {super.key,
      required this.state,
      required this.scale,
      this.onHover,
      this.onExit});
  @override
  Widget build(BuildContext context) {
    final panels = state.videoPanels;
    final backgrounds =
        panels.where((panel) => panel.kind != DebugLayerKind.sprites);
    final sprites =
        panels.where((panel) => panel.kind == DebugLayerKind.sprites);
    if (state.view == DebugView.patterns) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final row in _patternRows(backgrounds))
          Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [for (final panel in row) _panel(context, panel)]),
        for (final panel in sprites) _panel(context, panel),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (backgrounds.isNotEmpty)
        _layerGroup(
            context, backgrounds, const ValueKey('debug-background-layers')),
      if (sprites.isNotEmpty)
        _layerGroup(context, sprites, const ValueKey('debug-sprite-layers')),
    ]);
  }

  Widget _layerGroup(
      BuildContext context, Iterable<DebugVideoPanel> panels, Key key) {
    final rows = <int, List<DebugVideoPanel>>{};
    for (final panel in panels) {
      rows.putIfAbsent(panel.row ?? 0, () => []).add(panel);
    }
    final order = rows.keys.toList()..sort();
    return Column(
        key: key,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final row in order)
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final panel in rows[row]!) _panel(context, panel)
            ]),
        ]);
  }

  // Pack using source-pixel widths, so zoom does not change table grouping.
  // A small minimum leaves space for titles and palette controls.
  double _patternWidth(DebugVideoPanel panel) => math.max(
      96.0,
      math.min(DebugPatternTable.maxWidth.toDouble(),
          panel.raster.image.width.toDouble()));
  Iterable<List<DebugVideoPanel>> _patternRows(
      Iterable<DebugVideoPanel> panels) sync* {
    var row = <DebugVideoPanel>[], width = 0.0;
    for (final panel in panels) {
      final nextWidth = _patternWidth(panel);
      if (row.isNotEmpty &&
          (panel.row != row.last.row ||
              (panel.row == null &&
                  width + nextWidth > DebugPatternTable.maxWidth))) {
        yield row;
        row = [];
        width = 0;
      }
      row.add(panel);
      width += nextWidth;
    }
    if (row.isNotEmpty) yield row;
  }

  Widget _panel(BuildContext context, DebugVideoPanel panel) => Padding(
        padding: const EdgeInsets.all(2),
        child: SizedBox(
            width: state.view == DebugView.patterns
                ? _patternWidth(panel) * scale
                : null,
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(panel.name, style: Theme.of(context).textTheme.titleSmall),
              if (panel.paletteName != null) ...[
                Text(panel.paletteName!),
                SizedBox(
                    width: math.min(256, _patternWidth(panel) * scale),
                    child: Wrap(spacing: 1, runSpacing: 1, children: [
                      for (var i = 0; i < panel.palette.length; i++)
                        Tooltip(
                            message: i.toRadixString(16).toUpperCase(),
                            child: Container(
                                width: 15,
                                height: 15,
                                color: _rgba(panel.palette[i]))),
                    ])),
              ],
              if (panel.raster.image.buffer.isEmpty)
                const Text('No image in the current video mode')
              else
                _RasterView(
                    raster: panel.raster,
                    background: panel.background,
                    scale: state.view == DebugView.patterns &&
                            panel.raster.image.width >
                                DebugPatternTable.maxWidth
                        ? scale *
                            DebugPatternTable.maxWidth /
                            panel.raster.image.width
                        : scale,
                    numbers: state.patternNumbers,
                    bounds: state.patternBounds,
                    viewport: state.viewportBounds,
                    onHover: onHover,
                    onExit: onExit),
            ])),
      );
}

class _RasterView extends StatefulWidget {
  final DebugRaster raster;
  final int background;
  final double scale;
  final bool numbers, bounds, viewport;
  final ValueChanged<VideoHover>? onHover;
  final VoidCallback? onExit;
  const _RasterView(
      {required this.raster,
      required this.background,
      required this.scale,
      required this.numbers,
      required this.bounds,
      required this.viewport,
      this.onHover,
      this.onExit});
  @override
  State<_RasterView> createState() => _RasterViewState();
}

class _RasterViewState extends State<_RasterView> {
  ui.Image? _image;
  int _generation = 0;
  Offset? _pointer;
  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(_RasterView old) {
    super.didUpdateWidget(old);
    if (!identical(old.raster.image.buffer, widget.raster.image.buffer)) {
      _decode();
    }
    if (_pointer != null &&
        (!identical(old.raster.image.buffer, widget.raster.image.buffer) ||
            old.scale != widget.scale ||
            old.background != widget.background)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _emitHover();
      });
    }
  }

  void _decode() {
    final generation = ++_generation, buffer = widget.raster.image;
    ui.decodeImageFromPixels(
        buffer.buffer, buffer.width, buffer.height, ui.PixelFormat.rgba8888,
        (image) {
      if (!mounted || generation != _generation) {
        image.dispose();
        return;
      }
      final previous = _image;
      setState(() => _image = image);
      previous?.dispose();
    });
  }

  @override
  void dispose() {
    _generation++;
    _image?.dispose();
    super.dispose();
  }

  VideoHover? _hover() {
    if (!mounted || _pointer == null) return null;
    final box = context.findRenderObject() as RenderBox;
    final local = box.globalToLocal(_pointer!);
    if (!(Offset.zero & box.size).contains(local)) return null;
    return VideoHover(widget.raster, widget.background, local / widget.scale,
        _pointer!, _hover);
  }

  void _emitHover() {
    final hover = _hover();
    if (hover != null) {
      widget.onHover?.call(hover);
    } else {
      widget.onExit?.call();
    }
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
      onHover: (event) {
        _pointer = event.position;
        _emitHover();
      },
      onExit: (_) {
        _pointer = null;
        widget.onExit?.call();
      },
      child: RepaintBoundary(
          child: CustomPaint(
        size: Size(widget.raster.image.width * widget.scale,
            widget.raster.image.height * widget.scale),
        painter: _RasterPainter(_image, widget.raster, widget.background,
            widget.scale, widget.numbers, widget.bounds, widget.viewport),
      )));
}

void _paintAnnotations(Canvas canvas, DebugRaster raster,
    {required double scale,
    required bool numbers,
    required bool bounds,
    required bool viewport}) {
  void outline(DebugOutline shape, Color color, bool label) {
    if (shape.points.isEmpty) return;
    final path = Path()..moveTo(shape.points.first.$1, shape.points.first.$2);
    for (final p in shape.points.skip(1)) {
      path.lineTo(p.$1, p.$2);
    }
    path.close();
    if (bounds && color != Colors.greenAccent || color == Colors.greenAccent) {
      canvas.drawPath(
          path,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1 / scale);
    }
    if (label && shape.label != null) {
      final text = TextPainter(
          text: TextSpan(
              text: shape.label,
              style: const TextStyle(
                  fontSize: 6,
                  color: Colors.white,
                  backgroundColor: Colors.black)),
          textDirection: TextDirection.ltr)
        ..layout();
      text.paint(
          canvas, Offset(shape.points.first.$1 + 1, shape.points.first.$2 + 1));
      text.dispose();
    }
  }

  if (bounds || numbers) {
    for (final shape in raster.patterns) {
      outline(shape, Colors.orangeAccent, numbers);
    }
  }
  if (viewport) {
    for (final shape in raster.viewports) {
      outline(shape, Colors.greenAccent, false);
    }
  }
}

class _RasterPainter extends CustomPainter {
  final ui.Image? image;
  final DebugRaster raster;
  final int background;
  final double scale;
  final bool numbers, bounds, viewport;
  _RasterPainter(this.image, this.raster, this.background, this.scale,
      this.numbers, this.bounds, this.viewport);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = _rgba(background));
    canvas.save();
    canvas.scale(scale);
    canvas.clipRect(Rect.fromLTWH(
        0, 0, raster.image.width.toDouble(), raster.image.height.toDouble()));
    if (image != null) {
      canvas.drawImage(
          image!, Offset.zero, Paint()..filterQuality = FilterQuality.none);
    }
    _paintAnnotations(canvas, raster,
        scale: scale, numbers: numbers, bounds: bounds, viewport: viewport);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RasterPainter old) =>
      old.image != image ||
      old.raster != raster ||
      old.background != background ||
      old.scale != scale ||
      old.numbers != numbers ||
      old.bounds != bounds ||
      old.viewport != viewport;
}

/// A UI-only hover snapshot; refreshing it follows scrolling and new captures.
class VideoHover {
  final DebugRaster raster;
  final int background;
  final Offset native, global;
  final VideoHover? Function() refresh;
  const VideoHover(
      this.raster, this.background, this.native, this.global, this.refresh);
}

/// Original pixels at 3x, with the same enabled annotations as the source.
class VideoMagnifier extends StatelessWidget {
  static const extent = 300.0;
  final VideoHover hover;
  final bool numbers, bounds, viewport;
  const VideoMagnifier(
      {super.key,
      required this.hover,
      this.numbers = false,
      this.bounds = false,
      this.viewport = false});
  @override
  Widget build(BuildContext context) => IgnorePointer(
      child: Material(
          elevation: 8,
          child: SizedBox(
              width: extent,
              height: extent,
              child: CustomPaint(
                  painter:
                      _MagnifierPainter(hover, numbers, bounds, viewport)))));
}

class _MagnifierPainter extends CustomPainter {
  final VideoHover hover;
  final bool numbers, bounds, viewport;
  _MagnifierPainter(this.hover, this.numbers, this.bounds, this.viewport);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
        Offset.zero & size, Paint()..color = _rgba(hover.background));
    final image = hover.raster.image,
        bytes = ByteData.sublistView(image.buffer);
    const zoom = 3.0;
    final columns = (size.width / zoom).ceil(),
        rows = (size.height / zoom).ceil();
    final startX = (hover.native.dx - columns / 2).floor(),
        startY = (hover.native.dy - rows / 2).floor();
    final paint = Paint();
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < columns; x++) {
        final sx = startX + x, sy = startY + y;
        if (sx < 0 || sy < 0 || sx >= image.width || sy >= image.height) {
          continue;
        }
        paint.color =
            _rgba(bytes.getUint32((sy * image.width + sx) * 4, Endian.little));
        canvas.drawRect(Rect.fromLTWH(x * 3.0, y * 3.0, 3, 3), paint);
      }
    }
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.scale(zoom);
    canvas.translate(-startX.toDouble(), -startY.toDouble());
    canvas.clipRect(
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()));
    _paintAnnotations(canvas, hover.raster,
        scale: zoom, numbers: numbers, bounds: bounds, viewport: viewport);
    canvas.restore();
    canvas.drawRect(
        (Offset.zero & size).deflate(0.5),
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(_MagnifierPainter old) =>
      old.hover != hover ||
      old.numbers != numbers ||
      old.bounds != bounds ||
      old.viewport != viewport;
}
