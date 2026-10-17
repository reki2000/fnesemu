import 'dart:math' as math;
import 'dart:typed_data';

import 'types.dart';

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
              image.width, image.height, Uint32List.fromList(image.buffer)),
          viewports: viewports);

  /// Crops a scrolling tilemap, wrapping in both directions. The map keeps
  /// its viewport outlines; the screen retains translated tile annotations.
  DebugRaster cropWrapped(int x, int y, int width, int height) {
    final sw = image.width, sh = image.height;
    if (sw == 0 || sh == 0) return DebugRaster(ImageBuffer.empty());
    final dst = DebugCanvas(width, height);
    final sx = x % sw;
    for (var py = 0; py < height; py++) {
      final row = ((py + y) % sh) * sw;
      var px = 0, sourceX = sx;
      while (px < width) {
        final count = math.min(width - px, sw - sourceX);
        final offset = py * width + px;
        dst.pixels
            .setRange(offset, offset + count, image.buffer, row + sourceX);
        px += count;
        sourceX = 0;
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
      bool paintPixels = true,
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
        patterns.add(sx == 0 && sy == 0 ? shape : shape.translated(sx, sy));
      }
    }
    if (!paintPixels) return;
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

  DebugRaster raster() => DebugRaster(ImageBuffer(width, height, pixels),
      patterns: patterns, viewports: viewports);
}

/// Sprite admission in SAT/OAM order, once per row rather than per pixel.
/// Each result is indexed by the sprite's local (unflipped) row. Offscreen X
/// and transparent pixels still consume the line limit, as in hardware.
List<Uint8List> debugSpriteLineVisibility(
    List<(int y, int height)> sprites, int limit) {
  if (sprites.isEmpty) return [];
  final first = sprites.map((s) => s.$1).reduce(math.min);
  final last = sprites.map((s) => s.$1 + s.$2).reduce(math.max);
  final counts = Uint16List(last - first);
  final result = <Uint8List>[];
  for (final (y, height) in sprites) {
    final visible = Uint8List(height);
    for (var row = 0; row < height; row++) {
      final line = y + row - first;
      visible[row] = counts[line] < limit ? 1 : 0;
      counts[line]++;
    }
    result.add(visible);
  }
  return result;
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
