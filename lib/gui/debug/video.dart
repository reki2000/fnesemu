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
                    numbers: state.patternNumbers,
                    bounds: state.patternBounds,
                    viewport: state.viewportBounds,
                    scale: state.view == DebugView.patterns &&
                            panel.raster.image.width >
                                DebugPatternTable.maxWidth
                        ? scale *
                            DebugPatternTable.maxWidth /
                            panel.raster.image.width
                        : scale,
                    onHover: onHover,
                    onExit: onExit),
            ])),
      );
}

class _RasterView extends StatefulWidget {
  final DebugRaster raster;
  final int background;
  final bool numbers, bounds, viewport;
  final double scale;
  final ValueChanged<VideoHover>? onHover;
  final VoidCallback? onExit;
  const _RasterView(
      {required this.raster,
      required this.background,
      this.numbers = false,
      this.bounds = false,
      this.viewport = false,
      required this.scale,
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
            old.background != widget.background ||
            old.numbers != widget.numbers ||
            old.bounds != widget.bounds ||
            old.viewport != widget.viewport)) {
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
        _pointer!, _hover,
        numbers: widget.numbers,
        bounds: widget.bounds,
        viewport: widget.viewport);
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
        painter: _RasterPainter(
            _image, widget.raster, widget.background, widget.scale),
      )));
}

class _RasterPainter extends CustomPainter {
  final ui.Image? image;
  final DebugRaster raster;
  final int background;
  final double scale;
  _RasterPainter(this.image, this.raster, this.background, this.scale);
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
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RasterPainter old) =>
      old.image != image ||
      old.raster != raster ||
      old.background != background ||
      old.scale != scale;
}

/// A UI-only hover snapshot; refreshing it follows scrolling and new captures.
class VideoHover {
  final DebugRaster raster;
  final int background;
  final Offset native, global;
  final bool numbers, bounds, viewport;
  final VideoHover? Function() refresh;
  const VideoHover(
      this.raster, this.background, this.native, this.global, this.refresh,
      {this.numbers = false, this.bounds = false, this.viewport = false});
}

/// Original bitmap pixels enlarged at 3x.
class VideoMagnifier extends StatelessWidget {
  static const extent = 300.0;
  final VideoHover hover;
  const VideoMagnifier({super.key, required this.hover});
  @override
  Widget build(BuildContext context) => IgnorePointer(
      child: Material(
          elevation: 8,
          child: SizedBox(
              width: extent,
              height: extent,
              child: CustomPaint(painter: _MagnifierPainter(hover)))));
}

class _MagnifierPainter extends CustomPainter {
  final VideoHover hover;
  _MagnifierPainter(this.hover);
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
    if (hover.bounds) {
      for (final shape in hover.raster.patterns) {
        _drawMagnifierOutline(canvas, image, shape, startX, startY, columns,
            rows, const Color(0x80ffab00),
            skipTopLeft: true, blend: true);
      }
    }
    if (hover.numbers) {
      for (final shape in hover.raster.patterns) {
        _drawMagnifierLabel(canvas, image, bytes, shape, hover.background,
            startX, startY, columns, rows);
      }
    }
    if (hover.viewport) {
      for (final shape in hover.raster.viewports) {
        _drawMagnifierOutline(canvas, image, shape, startX, startY, columns,
            rows, _rgba(0xffaef069));
      }
    }
    canvas.drawRect(
        (Offset.zero & size).deflate(0.5),
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(_MagnifierPainter old) => old.hover != hover;
}

void _drawMagnifierOutline(Canvas canvas, ImageBuffer image, DebugOutline shape,
    int startX, int startY, int columns, int rows, Color color,
    {bool skipTopLeft = false, bool blend = false}) {
  if (shape.points.length < 2) return;
  var minX = double.infinity,
      minY = double.infinity,
      maxX = -double.infinity,
      maxY = -double.infinity,
      axisAligned = shape.points.length == 4;
  for (var i = 0; i < shape.points.length; i++) {
    final a = shape.points[i], b = shape.points[(i + 1) % shape.points.length];
    minX = math.min(minX, a.$1);
    minY = math.min(minY, a.$2);
    maxX = math.max(maxX, a.$1);
    maxY = math.max(maxY, a.$2);
    axisAligned &= a.$1 == b.$1 || a.$2 == b.$2;
  }
  if (maxX < startX ||
      minX >= startX + columns ||
      maxY < startY ||
      minY >= startY + rows) return;
  final zoomed = [
    for (final (x, y) in shape.points) ((x - startX) * 3, (y - startY) * 3)
  ];
  minX = zoomed.map((point) => point.$1).reduce(math.min);
  minY = zoomed.map((point) => point.$2).reduce(math.min);
  maxX = zoomed.map((point) => point.$1).reduce(math.max);
  maxY = zoomed.map((point) => point.$2).reduce(math.max);
  final drawn = blend ? <int>{} : null, paint = Paint()..color = color;
  void draw(int x, int y) {
    if (x < 0 || y < 0 || x >= columns * 3 || y >= rows * 3) return;
    final sourceX = startX + x ~/ 3, sourceY = startY + y ~/ 3;
    if (sourceX < 0 ||
        sourceY < 0 ||
        sourceX >= image.width ||
        sourceY >= image.height) return;
    final index = y * columns * 3 + x;
    if (drawn != null && !drawn.add(index)) return;
    canvas.drawRect(Rect.fromLTWH(x.toDouble(), y.toDouble(), 1, 1), paint);
  }

  if (axisAligned) {
    final left = (minX + 0.5).floor(),
        right = (maxX - 0.5).floor(),
        top = (minY + 0.5).floor(),
        bottom = (maxY - 0.5).floor();
    if (!skipTopLeft) {
      for (var x = left; x <= right; x++) {
        draw(x, top);
      }
      for (var y = top; y <= bottom; y++) {
        draw(left, y);
      }
    }
    for (var x = left; x <= right; x++) {
      draw(x, bottom);
    }
    for (var y = top; y < bottom; y++) {
      draw(right, y);
    }
    return;
  }

  var area = 0.0;
  for (var i = 0; i < zoomed.length; i++) {
    final a = zoomed[i], b = zoomed[(i + 1) % zoomed.length];
    area += a.$1 * b.$2 - b.$1 * a.$2;
  }
  final direction = area >= 0 ? 1.0 : -1.0;
  for (var i = 0; i < zoomed.length; i++) {
    final a = zoomed[i], b = zoomed[(i + 1) % zoomed.length];
    final dx = b.$1 - a.$1, dy = b.$2 - a.$2;
    if (skipTopLeft && (dy == 0 && a.$2 == minY || dx == 0 && a.$1 == minX)) {
      continue;
    }
    final length = math.sqrt(dx * dx + dy * dy);
    if (length == 0) continue;
    final steps = math.max(1, length.ceil()),
        nx = -dy / length * direction * 0.5,
        ny = dx / length * direction * 0.5;
    for (var step = 0; step <= steps; step++) {
      final t = step / steps;
      draw((a.$1 + dx * t + nx).floor(), (a.$2 + dy * t + ny).floor());
    }
  }
}

void _drawMagnifierLabel(
    Canvas canvas,
    ImageBuffer image,
    ByteData bytes,
    DebugOutline shape,
    int background,
    int startX,
    int startY,
    int columns,
    int rows) {
  if (shape.points.isEmpty || shape.label == null) return;
  final label = shape.label!, value = int.tryParse(shape.label!, radix: 16);
  if (value == null) return;
  final first = shape.points.first,
      x = first.$1.floor() + 1,
      y = first.$2.floor() + 1,
      width = IntImageExt.patternWidth * label.length,
      height = IntImageExt.digitPattern.length,
      glyphX = (x - startX) * 3,
      glyphY = (y - startY) * 3;
  if (glyphX + width <= 0 ||
      glyphX >= columns * 3 ||
      glyphY + height <= 0 ||
      glyphY >= rows * 3) return;

  var luminance = 0, count = 0;
  for (var py = 0; py < height; py++) {
    for (var px = 0; px < width; px++) {
      if (!value.drawHexValue(px, py, label.length)) continue;
      final sx = startX + (glyphX + px) ~/ 3,
          sy = startY + (glyphY + py) ~/ 3,
          pixel = sx < 0 || sy < 0 || sx >= image.width || sy >= image.height
              ? background
              : bytes.getUint32((sy * image.width + sx) * 4, Endian.little);
      luminance += _rasterLuminance(_compositeRasterColor(pixel, background));
      count++;
    }
  }
  final foreground =
      count == 0 || luminance ~/ count < 128 ? Colors.white : Colors.black;
  final paint = Paint()..color = foreground;
  for (var py = 0; py < height; py++) {
    for (var px = 0; px < width; px++) {
      if (!value.drawHexValue(px, py, label.length)) continue;
      canvas.drawRect(
          Rect.fromLTWH(
              (glyphX + px).toDouble(), (glyphY + py).toDouble(), 1, 1),
          paint);
    }
  }
}

int _rasterLuminance(int color) {
  final red = color & 0xff,
      green = color >> 8 & 0xff,
      blue = color >> 16 & 0xff;
  return (299 * red + 587 * green + 114 * blue) ~/ 1000;
}

int _compositeRasterColor(int color, int background) {
  final alpha = color >> 24 & 0xff;
  if (alpha == 0xff) return color;
  if (alpha == 0) return 0xff000000 | (background & 0xffffff);
  final inverse = 0xff - alpha;
  int channel(int shift) =>
      ((color >> shift & 0xff) * alpha +
          (background >> shift & 0xff) * inverse +
          0x7f) ~/
      0xff;
  return 0xff000000 | channel(16) << 16 | channel(8) << 8 | channel(0);
}
