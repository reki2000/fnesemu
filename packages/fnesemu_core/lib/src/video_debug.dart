import 'dart:math' as math;
import 'dart:typed_data';

import 'types.dart';
import 'util/int.dart';

/// Images and colours use the same little-endian RGBA words as ImageBuffer.
enum DebugView { cpu, layers, patterns }

enum LayerView { screen, map }

enum DebugLayerKind { background, sprites, framebuffer }

class DebugOutline {
  final List<(double, double)> points;
  final String? label;
  DebugOutline(Iterable<(double, double)> points, {this.label})
      : points = List.unmodifiable(points);
  factory DebugOutline.rect(num x, num y, num width, num height,
          {String? label}) =>
      DebugOutline([
        (x.toDouble(), y.toDouble()),
        ((x + width).toDouble(), y.toDouble()),
        ((x + width).toDouble(), (y + height).toDouble()),
        (x.toDouble(), (y + height).toDouble())
      ], label: label);
  DebugOutline translated(double dx, double dy) =>
      DebugOutline(points.map((p) => (p.$1 + dx, p.$2 + dy)), label: label);

  bool get hasArea {
    var area = 0.0;
    for (var i = 0; i < points.length; i++) {
      final a = points[i], b = points[(i + 1) % points.length];
      area += a.$1 * b.$2 - b.$1 * a.$2;
    }
    return area.abs() > 0.000001;
  }

  /// Clip transformed tile outlines to the object's actual drawing box.
  DebugOutline clipped(double left, double top, double width, double height) {
    var result = points.toList();
    for (var edge = 0; edge < 4; edge++) {
      final input = result;
      result = [];
      if (input.isEmpty) break;
      bool inside((double, double) p) => switch (edge) {
            0 => p.$1 >= left,
            1 => p.$1 <= left + width,
            2 => p.$2 >= top,
            _ => p.$2 <= top + height,
          };
      (double, double) intersection((double, double) a, (double, double) b) {
        if (edge < 2) {
          final x = edge == 0 ? left : left + width;
          final fraction = (x - a.$1) / (b.$1 - a.$1);
          return (x, a.$2 + fraction * (b.$2 - a.$2));
        }
        final y = edge == 2 ? top : top + height;
        final fraction = (y - a.$2) / (b.$2 - a.$2);
        return (a.$1 + fraction * (b.$1 - a.$1), y);
      }

      var previous = input.last;
      for (final current in input) {
        if (inside(current) != inside(previous)) {
          result.add(intersection(previous, current));
        }
        if (inside(current)) result.add(current);
        previous = current;
      }
    }
    return DebugOutline(result, label: label);
  }
}

/// A captured image plus annotations in native pixel coordinates.
class DebugRaster {
  final ImageBuffer image;
  final List<DebugOutline> patterns, viewports;
  DebugRaster(this.image,
      {Iterable<DebugOutline> patterns = const [],
      Iterable<DebugOutline> viewports = const []})
      : patterns = List.unmodifiable(patterns),
        viewports = List.unmodifiable(viewports);
  factory DebugRaster.copy(ImageBuffer image,
          {Iterable<DebugOutline> viewports = const []}) =>
      DebugRaster(
          ImageBuffer(
              image.width, image.height, Uint8List.fromList(image.buffer)),
          viewports: viewports);

  /// Returns a copy with debug annotations drawn into its native pixels.
  /// Pixel writes stay integer-only so clients can display and magnify the
  /// resulting bitmap without recreating overlay geometry.
  DebugRaster annotated(
      {bool numbers = false,
      bool bounds = false,
      bool viewport = false,
      int background = 0xff000000}) {
    final drawPatterns = (numbers || bounds) && patterns.isNotEmpty,
        drawViewports = viewport && viewports.isNotEmpty;
    if (!drawPatterns && !drawViewports) {
      return this;
    }
    final canvas = DebugCanvas(image.width, image.height),
        source = ByteData.sublistView(image.buffer);
    final sourceBuffer = image.buffer;
    if (sourceBuffer.offsetInBytes % 4 == 0 &&
        sourceBuffer.lengthInBytes >= canvas.pixels.length * 4) {
      canvas.pixels.setAll(
          0,
          Uint32List.view(sourceBuffer.buffer, sourceBuffer.offsetInBytes,
              canvas.pixels.length));
    } else {
      for (var i = 0; i < canvas.pixels.length; i++) {
        canvas.pixels[i] = source.getUint32(i * 4, Endian.little);
      }
    }
    canvas.patterns.addAll(patterns);
    canvas.viewports.addAll(viewports);
    final glyphCache = <(int, int), List<int>>{}, contrastCache = <int, int>{};
    if (drawPatterns) {
      for (final pattern in patterns) {
        if (bounds) {
          _drawOutline(canvas, pattern, 0xff00abff,
              skipTopLeft: true, blend: true, background: background);
        }
        if (numbers && pattern.label != null) {
          _drawHexLabel(canvas, pattern, pattern.label!, background, glyphCache,
              contrastCache);
        }
      }
    }
    if (drawViewports) {
      for (final shape in viewports) {
        _drawOutline(canvas, shape, 0xffaef069);
      }
    }
    return canvas.raster();
  }

  /// Crops a scrolling tilemap, wrapping in both directions. The map keeps
  /// its viewport outlines; the screen retains translated tile annotations.
  DebugRaster cropWrapped(int x, int y, int width, int height) {
    final sw = image.width, sh = image.height;
    if (sw == 0 || sh == 0) return DebugRaster(ImageBuffer.empty());
    final src = ByteData.sublistView(image.buffer);
    final dst = DebugCanvas(width, height);
    for (var py = 0; py < height; py++) {
      for (var px = 0; px < width; px++) {
        dst.pixels[py * width + px] = src.getUint32(
            (((py + y) % sh) * sw + (px + x) % sw) * 4, Endian.little);
      }
    }
    for (var oy = -(y % sh); oy < height; oy += sh) {
      for (var ox = -(x % sw); ox < width; ox += sw) {
        for (final shape in patterns) {
          final shifted = shape.translated(ox.toDouble(), oy.toDouble());
          if (shifted.points.any((p) =>
              p.$1 >= -32 &&
              p.$1 <= width + 32 &&
              p.$2 >= -32 &&
              p.$2 <= height + 32)) {
            dst.patterns.add(shifted);
          }
        }
      }
    }
    return dst.raster();
  }
}

void _drawOutline(DebugCanvas canvas, DebugOutline shape, int color,
    {bool skipTopLeft = false,
    bool blend = false,
    int background = 0xff000000}) {
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
  if (axisAligned) {
    final left = (minX + 0.5).floor(),
        right = (maxX - 0.5).floor(),
        top = (minY + 0.5).floor(),
        bottom = (maxY - 0.5).floor();
    void draw(int x, int y) =>
        _plotOutline(canvas, x, y, color, blend, background);

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
  for (var i = 0; i < shape.points.length; i++) {
    final a = shape.points[i], b = shape.points[(i + 1) % shape.points.length];
    area += a.$1 * b.$2 - b.$1 * a.$2;
  }
  final direction = area >= 0 ? 1.0 : -1.0;
  final drawn = blend ? <int>{} : null;
  for (var i = 0; i < shape.points.length; i++) {
    final a = shape.points[i], b = shape.points[(i + 1) % shape.points.length];
    final dx = b.$1 - a.$1, dy = b.$2 - a.$2;
    if (skipTopLeft && (dy == 0 && a.$2 == minY || dx == 0 && a.$1 == minX)) {
      continue;
    }
    final length = math.sqrt(dx * dx + dy * dy);
    if (length == 0) continue;
    final steps = math.max(1, length.ceil());
    final nx = -dy / length * direction * 0.5;
    final ny = dx / length * direction * 0.5;
    for (var step = 0; step <= steps; step++) {
      final t = step / steps;
      final x = (a.$1 + dx * t + nx).floor(),
          y = (a.$2 + dy * t + ny).floor(),
          index = y * canvas.width + x;
      if (drawn != null &&
          (x < 0 ||
              y < 0 ||
              x >= canvas.width ||
              y >= canvas.height ||
              !drawn.add(index))) {
        continue;
      }
      _plotOutline(canvas, x, y, color, blend, background);
    }
  }
}

void _drawHexLabel(
    DebugCanvas canvas,
    DebugOutline shape,
    String label,
    int background,
    Map<(int, int), List<int>> glyphCache,
    Map<int, int> contrastCache) {
  final value = int.tryParse(label, radix: 16), first = shape.points.first;
  if (value == null) return;
  final x = first.$1.floor() + 1, y = first.$2.floor() + 1;
  final rows = glyphCache.putIfAbsent(
      (value, label.length), () => _hexGlyphRows(value, label.length));
  for (var py = 0; py < IntImageExt.digitPattern.length; py++) {
    var row = rows[py];
    while (row != 0) {
      final bit = row & -row, px = bit.bitLength - 1;
      _putPixel(canvas, x + px, y + py,
          _contrastColor(canvas, x + px, y + py, background, contrastCache));
      row ^= bit;
    }
  }
}

List<int> _hexGlyphRows(int value, int characters) => [
      for (var y = 0; y < IntImageExt.digitPattern.length; y++)
        () {
          var row = 0;
          for (var x = 0; x < IntImageExt.patternWidth * characters; x++) {
            if (value.drawHexValue(x, y, characters)) row |= 1 << x;
          }
          return row;
        }(),
    ];

int _contrastColor(DebugCanvas canvas, int x, int y, int background,
    Map<int, int> contrastCache) {
  if (x < 0 || y < 0 || x >= canvas.width || y >= canvas.height) {
    return 0xffffffff;
  }
  final pixel = _composite(canvas.pixels[y * canvas.width + x], background),
      cached = contrastCache[pixel];
  if (cached != null) return cached;
  final red = pixel & 0xff,
      green = pixel >> 8 & 0xff,
      blue = pixel >> 16 & 0xff,
      luminance = (299 * red + 587 * green + 114 * blue) ~/ 1000;
  return contrastCache[pixel] = luminance >= 128 ? 0xff000000 : 0xffffffff;
}

int _composite(int color, int background) {
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

void _plotOutline(
    DebugCanvas canvas, int x, int y, int color, bool blend, int background) {
  if (blend) {
    _blendPixel(canvas, x, y, color, background);
  } else {
    _putPixel(canvas, x, y, color);
  }
}

void _blendPixel(DebugCanvas canvas, int x, int y, int color, int background) {
  if (x < 0 || y < 0 || x >= canvas.width || y >= canvas.height) return;
  final index = y * canvas.width + x,
      original = _composite(canvas.pixels[y * canvas.width + x], background);
  final red = ((original & 0xff) + (color & 0xff)) >> 1,
      green = ((original >> 8 & 0xff) + (color >> 8 & 0xff)) >> 1,
      blue = ((original >> 16 & 0xff) + (color >> 16 & 0xff)) >> 1;
  canvas.pixels[index] = 0xff000000 | blue << 16 | green << 8 | red;
}

void _putPixel(DebugCanvas canvas, int x, int y, int color) {
  if (x >= 0 && y >= 0 && x < canvas.width && y < canvas.height) {
    canvas.pixels[y * canvas.width + x] = color;
  }
}

/// Affine debug geometry is shared; the hardware interpretation of the
/// coefficients remains in the individual core.
class DebugAffine {
  final double a, b, c, d, x, y;
  const DebugAffine(this.a, this.b, this.c, this.d, this.x, this.y);
  (double, double) project(double u, double v) =>
      (a * u + b * v + x, c * u + d * v + y);
  DebugAffine? get inverse {
    final det = a * d - b * c;
    if (det == 0) return null;
    return DebugAffine(d / det, -b / det, -c / det, a / det,
        (b * y - d * x) / det, (c * x - a * y) / det);
  }

  DebugOutline outline(DebugOutline shape) =>
      DebugOutline(shape.points.map((p) => project(p.$1, p.$2)),
          label: shape.label);
}

/// Layer names and the distinction between screen and map belong to the core.
class DebugVideoLayer {
  final String name;
  final int row;
  final DebugLayerKind kind;
  final bool hasMap;
  final int originalBackground, alternativeBackground;
  final DebugRaster Function(bool fullMap) capture;
  DebugVideoLayer(this.name, this.capture,
      {this.row = 0,
      this.kind = DebugLayerKind.background,
      this.hasMap = false,
      this.originalBackground = 0xff000000,
      this.alternativeBackground = 0xff808080});
}

class DebugPalette {
  final String name;
  final List<int> colors;
  DebugPalette(this.name, Iterable<int> colors)
      : colors = List.unmodifiable(colors);
}

/// A pattern source supplies native colour indices, never rendered UI text.
class DebugPatternTable {
  final DebugLayerKind kind;

  /// Tables with the same row appear together; null uses width-based packing.
  final int? row;
  static const maxWidth = 512;
  final String name;
  final int count, width, height, colorCount;
  final int Function(int pattern, int x, int y) readPixel;
  final List<DebugPalette> palettes;
  final int? transparentIndex;
  final bool directColor;
  final int Function(int)? patternNumber;
  final int originalBackground, alternativeBackground;
  DebugPatternTable(this.name,
      {this.kind = DebugLayerKind.background,
      this.row,
      required this.count,
      this.width = 8,
      this.height = 8,
      required this.colorCount,
      required this.readPixel,
      Iterable<DebugPalette> palettes = const [],
      this.transparentIndex = 0,
      this.directColor = false,
      this.patternNumber,
      this.originalBackground = 0xff000000,
      this.alternativeBackground = 0xff808080})
      : palettes = List.unmodifiable(palettes);

  /// Offset zero is grayscale; actual palettes are cycled independently for
  /// each source, so clients need no bank IDs or hardware-specific ranges.
  DebugVideoPanel capture(int paletteOffset, bool alternative,
      {int blockSize = 8}) {
    final choices = directColor ? 1 : palettes.length + 1;
    final selected = paletteOffset % choices;
    final palette = selected == 0 ? null : palettes[selected - 1];
    final columnsInBlock = math.max(1, blockSize ~/ width);
    final rowsInBlock = math.max(1, blockSize ~/ height);
    final blockWidth = columnsInBlock * width,
        blockHeight = rowsInBlock * height;
    final patternsInBlock = columnsInBlock * rowsInBlock;
    final blocks =
        math.max(1, (count + patternsInBlock - 1) ~/ patternsInBlock);
    final blocksPerRow = math.min(blocks, math.max(1, maxWidth ~/ blockWidth));
    final canvas = DebugCanvas(blocksPerRow * blockWidth,
        ((blocks + blocksPerRow - 1) ~/ blocksPerRow) * blockHeight);
    for (var n = 0; n < count; n++) {
      final block = n ~/ patternsInBlock, cell = n % patternsInBlock;
      final x =
          (block % blocksPerRow) * blockWidth + (cell % columnsInBlock) * width;
      final y = (block ~/ blocksPerRow) * blockHeight +
          (cell ~/ columnsInBlock) * height;
      canvas.tile(patternNumber?.call(n) ?? n, x, y, width, height, (x, y) {
        final index = readPixel(n, x, y);
        if (index == transparentIndex || index < 0) return 0;
        if (directColor) return index;
        if (palette != null && index < palette.colors.length) {
          return palette.colors[index];
        }
        final gray = colorCount > 1
            ? (index * 255 ~/ (colorCount - 1)).clamp(0, 255)
            : 0;
        return 0xff000000 | gray * 0x010101;
      });
    }
    return DebugVideoPanel(name, canvas.raster(),
        alternative ? alternativeBackground : originalBackground,
        kind: kind,
        row: row,
        paletteName:
            directColor ? 'Direct color' : palette?.name ?? 'Grayscale',
        palette: directColor
            ? []
            : palette?.colors ??
                [
                  for (var i = 0; i < colorCount; i++)
                    0xff000000 |
                        (i * 255 ~/ math.max(1, colorCount - 1)) * 0x010101
                ]);
  }
}

class DebugVideoPanel {
  final String name;
  final int? row;
  final DebugLayerKind kind;
  final DebugRaster raster;
  final int background;
  final String? paletteName;
  final List<int> palette;
  DebugVideoPanel(this.name, this.raster, this.background,
      {this.row = 0,
      this.kind = DebugLayerKind.background,
      this.paletteName,
      Iterable<int> palette = const []})
      : palette = List.unmodifiable(palette);
}

/// Screen-space contours of native pattern cells. Cores provide the source
/// cell identity for each sampled pixel, including raster scroll and mosaic.
/// This stays entirely outside the runtime rendering path.
class DebugPatternRegions {
  final int width, height;
  final Int32List _cells;
  final _ids = <Object, int>{};
  final _labels = <String>[];
  DebugPatternRegions(this.width, this.height)
      : _cells = Int32List(width * height)..fillRange(0, width * height, -1);
  void mark(int x, int y, Object cell, int number) {
    _cells[y * width + x] = _ids.putIfAbsent(cell, () {
      _labels.add(number.toRadixString(16).toUpperCase());
      return _labels.length - 1;
    });
  }

  List<DebugOutline> outlines() {
    final edges = <int, Map<int, List<int>>>{};
    final stride = width + 1;
    void edge(int id, int start, int end) =>
        edges.putIfAbsent(id, () => {}).putIfAbsent(start, () => []).add(end);
    int cell(int x, int y) => x < 0 || y < 0 || x >= width || y >= height
        ? -1
        : _cells[y * width + x];
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final id = cell(x, y);
        if (id < 0) continue;
        final tl = y * stride + x, tr = tl + 1, bl = tl + stride, br = bl + 1;
        if (cell(x, y - 1) != id) edge(id, tl, tr);
        if (cell(x + 1, y) != id) edge(id, tr, br);
        if (cell(x, y + 1) != id) edge(id, br, bl);
        if (cell(x - 1, y) != id) edge(id, bl, tl);
      }
    }
    final result = <DebugOutline>[];
    for (final entry in edges.entries) {
      final remaining = entry.value;
      while (remaining.isNotEmpty) {
        final start = remaining.keys.first;
        var vertex = start;
        final vertices = <int>[];
        do {
          vertices.add(vertex);
          final candidates = remaining[vertex];
          if (candidates == null) break;
          final next = candidates.removeLast();
          if (candidates.isEmpty) remaining.remove(vertex);
          vertex = next;
        } while (vertex != start);
        // Only retain corners; long straight boundaries need two points.
        final points = <(double, double)>[];
        for (var n = 0; n < vertices.length; n++) {
          final before = vertices[(n + vertices.length - 1) % vertices.length],
              here = vertices[n],
              after = vertices[(n + 1) % vertices.length];
          if (here - before == after - here) continue;
          points.add(((here % stride).toDouble(), (here ~/ stride).toDouble()));
        }
        if (points.length >= 3) {
          result.add(DebugOutline(points, label: _labels[entry.key]));
        }
      }
    }
    return result;
  }
}

/// Common debug-only placement and pixel-format helpers. Runtime renderers
/// never call this canvas or add annotation work to their hot paths.
class DebugCanvas {
  final int width, height;
  final Uint32List pixels;
  final patterns = <DebugOutline>[];
  final viewports = <DebugOutline>[];
  DebugCanvas(this.width, this.height) : pixels = Uint32List(width * height);

  void tile(int number, int x, int y, int w, int h, int Function(int, int) rgba,
      {bool flipX = false,
      bool flipY = false,
      bool wrapX = false,
      bool wrapY = false,
      String? label}) {
    final shape = DebugOutline.rect(x, y, w, h,
        label: label ?? number.toRadixString(16).toUpperCase());
    for (final sy in wrapY
        ? [
            0.0,
            if (y < 0) height.toDouble(),
            if (y + h > height) -height.toDouble()
          ]
        : [0.0]) {
      for (final sx in wrapX
          ? [
              0.0,
              if (x < 0) width.toDouble(),
              if (x + w > width) -width.toDouble()
            ]
          : [0.0]) {
        patterns.add(shape.translated(sx, sy));
      }
    }
    for (var py = 0; py < h; py++) {
      final dy = wrapY ? (y + py) % height : y + py;
      if (dy < 0 || dy >= height) continue;
      for (var px = 0; px < w; px++) {
        final dx = wrapX ? (x + px) % width : x + px;
        if (dx < 0 || dx >= width) continue;
        final color = rgba(flipX ? w - 1 - px : px, flipY ? h - 1 - py : py);
        if (color >>> 24 != 0) pixels[dy * width + dx] = color;
      }
    }
  }

  /// Project native map cells through the inverse texture transform.
  void projectPatterns(DebugRaster map, DebugAffine textureTransform,
      {bool wrap = false}) {
    final inverse = textureTransform.inverse;
    if (inverse == null) return;
    final corners = [
      textureTransform.project(0, 0),
      textureTransform.project(width.toDouble(), 0),
      textureTransform.project(width.toDouble(), height.toDouble()),
      textureTransform.project(0, height.toDouble())
    ];
    final minX = corners.map((p) => p.$1).reduce(math.min),
        maxX = corners.map((p) => p.$1).reduce(math.max);
    final minY = corners.map((p) => p.$2).reduce(math.min),
        maxY = corners.map((p) => p.$2).reduce(math.max);
    final firstX = wrap ? (minX / map.image.width).floor() : 0,
        lastX = wrap ? (maxX / map.image.width).floor() : 0;
    final firstY = wrap ? (minY / map.image.height).floor() : 0,
        lastY = wrap ? (maxY / map.image.height).floor() : 0;
    for (var oy = firstY; oy <= lastY; oy++)
      for (var ox = firstX; ox <= lastX; ox++) {
        for (final shape in map.patterns) {
          final projected = inverse
              .outline(shape.translated(ox * map.image.width.toDouble(),
                  oy * map.image.height.toDouble()))
              .clipped(0, 0, width.toDouble(), height.toDouble());
          if (projected.hasArea) patterns.add(projected);
        }
      }
  }

  void viewport(int x, int y, int w, int h) {
    if (width == 0 ||
        height == 0 ||
        x % width == 0 && y % height == 0 && w == width && h == height) {
      return;
    }
    var remainingY = h, sy = y % height;
    while (remainingY > 0) {
      final segmentH = math.min(remainingY, height - sy);
      var remainingX = w, sx = x % width;
      while (remainingX > 0) {
        final segmentW = math.min(remainingX, width - sx);
        viewports.add(DebugOutline.rect(sx, sy, segmentW, segmentH));
        remainingX -= segmentW;
        sx = 0;
      }
      remainingY -= segmentH;
      sy = 0;
    }
  }

  DebugRaster raster() =>
      DebugRaster(ImageBuffer(width, height, pixels.buffer.asUint8List()),
          patterns: patterns, viewports: viewports);
}

int debugPlanarPixel(
    int Function(int) read, int base, int x, int y, List<int> planes,
    {int rowStride = 2}) {
  var color = 0;
  for (var plane = 0; plane < planes.length; plane++) {
    color |=
        ((read(base + planes[plane] + y * rowStride) >> (7 - x)) & 1) << plane;
  }
  return color;
}

int debugPackedPixel(int Function(int) read, int base, int x, int y,
    {int bits = 4, int stride = 4, bool highFirst = false}) {
  final byte = read(base + y * stride + (x * bits ~/ 8));
  if (bits == 8) return byte;
  final shift = ((x & 1) == (highFirst ? 0 : 1)) ? 4 : 0;
  return (byte >> shift) & 15;
}

int debugRgb555(int color) {
  int expand(int c) => (c << 3) | (c >> 2);
  return 0xff000000 |
      expand(color & 31) |
      expand((color >> 5) & 31) << 8 |
      expand((color >> 10) & 31) << 16;
}
