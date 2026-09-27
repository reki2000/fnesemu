import 'dart:math' as math;
import 'dart:typed_data';
import 'bus.dart';

class N64Tile {
  int format = 0, size = 0, line = 0, tmem = 0, palette = 0;
  int sMode = 0, tMode = 0, sMask = 0, tMask = 0, sShift = 0, tShift = 0;
  double left = 0, top = 0, right = 0, bottom = 0;
}

class N64Vertex {
  final List<double> clip, color;
  final double s, t;
  const N64Vertex(this.clip, this.color, this.s, this.t);
  N64Vertex mix(N64Vertex b, double f) => N64Vertex(
      List.generate(4, (i) => clip[i] + (b.clip[i] - clip[i]) * f),
      List.generate(4, (i) => color[i] + (b.color[i] - color[i]) * f),
      s + (b.s - s) * f,
      t + (b.t - t) * f);
}

/// Independent Fast3D/F3DEX task decoder and software rasterizer.
/// Uses the documented GBI protocol; does not execute RSP instruction binaries.
class N64Graphics {
  final N64Bus bus;
  final segments = List<int>.filled(16, 0);
  final vertices = List<N64Vertex?>.filled(80, null);
  final tiles = List.generate(8, (_) => N64Tile());
  final tmem = Uint8List(4096);
  final _textureColor = Float64List(4), _combined = Float64List(4);
  final _shade = Float64List(4);
  static const _white = <double>[255, 255, 255, 255];
  static final _fiveBit = List<double>.generate(32, (v) => v * 255 / 31);
  // Pixel scratch buffers are consumed synchronously, never retained by vertices.
  List<double> _textureRgba(
      double red, double green, double blue, double alpha) {
    _textureColor[0] = red;
    _textureColor[1] = green;
    _textureColor[2] = blue;
    _textureColor[3] = alpha;
    return _textureColor;
  }

  List<double> _texture16(int value) => _textureRgba(
      _fiveBit[(value >> 11) & 31],
      _fiveBit[(value >> 6) & 31],
      _fiveBit[(value >> 1) & 31],
      (value & 1) * 255.0);

  final lights = List.generate(8, (_) => List<double>.filled(6, 0));
  List<double> model = identity(), projection = identity();
  final stack = <List<double>>[];
  List<double> scale = [160, 120, 511], translate = [160, 120, 511];
  int geometry = 0, numLights = 1;
  int colorImage = 0, colorSize = 2, width = 320, zImage = 0;
  int textureImage = 0, textureSize = 2, textureWidth = 1, textureFormat = 0;
  int activeTile = 0;
  double textureS = 1, textureT = 1;
  bool textureOn = false;
  int otherHigh = 0, otherLow = 0, combine0 = 0, combine1 = 0, fillColor = 0;
  List<double> primitive = [255, 255, 255, 255],
      environment = [255, 255, 255, 255],
      fog = [0, 0, 0, 0];
  int scLeft = 0, scTop = 0, scRight = 320, scBottom = 240;
  int tasks = 0, triangles = 0;
  final depths = <int, Float64List>{};
  bool extended = false;
  bool rasterize =
      true; // Optional headless fast-forward; normal execution renders every task.
  N64Graphics(this.bus);
  static List<double> identity() =>
      [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
  void reset() {
    tasks = triangles = 0;
    segments.fillRange(0, 16, 0);
    vertices.fillRange(0, 80, null);
    model = identity();
    projection = identity();
    stack.clear();
    depths.clear();
    tmem.fillRange(0, tmem.length, 0);
    for (var i = 0; i < tiles.length; i++) {
      tiles[i] = N64Tile();
    }
    for (final light in lights) {
      light.fillRange(0, light.length, 0);
    }
    scale = [160, 120, 511];
    translate = [160, 120, 511];
    geometry = 0;
    numLights = 1;
    colorImage = zImage = textureImage = 0;
    width = 320;
    colorSize = textureSize = 2;
    textureWidth = 1;
    textureFormat = activeTile = 0;
    textureS = textureT = 1;
    textureOn = false;
    otherHigh = otherLow = combine0 = combine1 = fillColor = 0;
    primitive = [255, 255, 255, 255];
    environment = [255, 255, 255, 255];
    fog = [0, 0, 0, 0];
    scLeft = scTop = 0;
    scRight = 320;
    scBottom = 240;
    extended = false;
  }

  int resolve(int addr) =>
      ((addr & 0xffffff) + segments[(addr >> 24) & 15]) & 0x7fffff;
  int u(int addr, int size) => bus.ramRead(addr, size);
  double signed(int addr, int size) =>
      u(addr, size).toSigned(size * 8).toDouble();
  List<double> matrix(int addr) => List.generate(
      16, (i) => signed(addr + i * 2, 2) + u(addr + 32 + i * 2, 2) / 65536);
  List<double> multiply(List<double> a, List<double> b) =>
      List.generate(16, (i) {
        final row = i ~/ 4, col = i % 4;
        return List.generate(4, (k) => a[row * 4 + k] * b[k * 4 + col])
            .reduce((x, y) => x + y);
      });
  List<double> transform(List<double> v, List<double> m) => List.generate(
      4,
      (i) =>
          List.generate(4, (k) => v[k] * m[k * 4 + i]).reduce((a, b) => a + b));
  void task(int address, int size, int ucodeData, int ucodeSize) {
    final end = math.min(bus.ram.length, ucodeData + math.min(ucodeSize, 2048));
    final name = String.fromCharCodes(bus.ram.sublist(ucodeData, end.toInt()));
    extended = name.contains('F3DEX') || name.contains('F3DLP');
    tasks++;
    displayList(address);
  }

  void displayList(int address) {
    var pc = address & 0x7fffff;
    final returns = <int>[];
    for (var commands = 0; commands < 100000; commands++) {
      final w0 = u(pc, 4), w1 = u(pc + 4, 4), op = w0 >> 24;
      pc += 8;
      switch (op) {
        case 0:
          break;
        case 1:
          final flags = (w0 >> 16) & 255, m = matrix(resolve(w1));
          if ((flags & 1) != 0) {
            projection = (flags & 2) != 0 ? m : multiply(m, projection);
          } else {
            if ((flags & 4) != 0) {
              if (stack.length >= 32) {
                throw StateError('RSP matrix stack overflow');
              }
              stack.add(List.of(model));
            }
            model = (flags & 2) != 0 ? m : multiply(m, model);
          }
        case 3:
          final index = (w0 >> 16) & 255, addr = resolve(w1);
          if (index == 0x80) {
            scale = List.generate(3, (i) => signed(addr + i * 2, 2) / 4);
            translate =
                List.generate(3, (i) => signed(addr + 8 + i * 2, 2) / 4);
          } else if (index >= 0x86 && index <= 0x94) {
            final l = lights[(index - 0x86) ~/ 2];
            for (var i = 0; i < 3; i++) {
              l[i] = u(addr + i, 1).toDouble();
              l[i + 3] = signed(addr + 8 + i, 1) / 127;
            }
          } else if (index != 0x82 && index != 0x84) {
            throw UnsupportedError('RSP MOVEMEM $index');
          }
        case 4:
          final count = extended ? ((w0 >> 10) & 63) : (((w0 >> 20) & 15) + 1);
          final first = extended ? ((w0 >> 17) & 127) : ((w0 >> 16) & 15);
          final addr = resolve(w1), combined = multiply(model, projection);
          if (first + count > vertices.length) {
            throw StateError('RSP vertex buffer overflow');
          }
          for (var i = 0; i < count; i++) {
            final p = addr + i * 16;
            final clip = transform(
                [signed(p, 2), signed(p + 2, 2), signed(p + 4, 2), 1],
                combined);
            final color = List.generate(4, (c) => u(p + 12 + c, 1).toDouble());
            if ((geometry & 0x20000) != 0) {
              final normal = [
                signed(p + 12, 1) / 127,
                signed(p + 13, 1) / 127,
                signed(p + 14, 1) / 127
              ];
              final n = List.generate(
                  3,
                  (c) =>
                      normal[0] * model[c] +
                      normal[1] * model[4 + c] +
                      normal[2] * model[8 + c]);
              final length = math.sqrt(n.fold(0.0, (v, x) => v + x * x));
              if (length > 0) {
                for (var c = 0; c < 3; c++) {
                  n[c] /= length;
                }
              }
              final ambient = lights[numLights.clamp(0, 7)];
              for (var c = 0; c < 3; c++) {
                color[c] = ambient[c];
              }
              for (var l = 0; l < numLights.clamp(0, 7); l++) {
                final light = lights[l];
                final dot = math.max(
                    0.0, n[0] * light[3] + n[1] * light[4] + n[2] * light[5]);
                for (var c = 0; c < 3; c++) {
                  color[c] += light[c] * dot;
                }
              }
            }
            vertices[first + i] = N64Vertex(
                clip,
                color,
                signed(p + 8, 2) / 32 * textureS,
                signed(p + 10, 2) / 32 * textureT);
          }
        case 6:
          if (((w0 >> 16) & 255) == 0) {
            if (returns.length >= 64) {
              throw StateError('RSP display list stack overflow');
            }
            returns.add(pc);
          }
          pc = resolve(w1);
        case 0xb8:
          if (returns.isEmpty) return;
          pc = returns.removeLast();
        case 0xbd:
          if (stack.isNotEmpty) model = stack.removeLast();
        case 0xbc:
          final index = w0 & 255, offset = (w0 >> 8) & 0xffff;
          if (index == 6) {
            segments[(offset ~/ 4) & 15] = w1 & 0xffffff;
          } else if (index == 2) {
            numLights = extended ? w1 ~/ 24 : ((w1 & 0x7fffffff) ~/ 32 - 1);
          } else if (index == 10) {
            final l = lights[(offset ~/ 32).clamp(0, 7)];
            for (var i = 0; i < 3; i++) {
              l[i] = ((w1 >> ((3 - i) * 8)) & 255).toDouble();
            }
          } else if (![0, 4, 8, 14].contains(index)) {
            throw UnsupportedError('RSP MOVEWORD $index');
          }
        case 0xbb:
          activeTile = (w0 >> 8) & 7;
          textureOn = (w0 & 255) != 0;
          textureS = ((w1 >> 16) & 0xffff) / 65536;
          textureT = (w1 & 0xffff) / 65536;
        case 0xb7:
          geometry |= w1;
        case 0xb6:
          geometry &= ~w1;
        case 0xba:
          final shift = (w0 >> 8) & 255, length = w0 & 255;
          final mask = ((1 << length) - 1) << shift;
          otherHigh = (otherHigh & ~mask) | (w1 & mask);
        case 0xb9:
          final shift = (w0 >> 8) & 255, length = w0 & 255;
          final mask = ((1 << length) - 1) << shift;
          otherLow = (otherLow & ~mask) | (w1 & mask);
        case 0xbf:
          drawIndices(w1, extended ? 2 : 10);
        case 0xb1:
          drawIndices(w0, 2);
          drawIndices(w1, 2);
        case 0xbe:
          break; // CULLDL is an optional visibility optimization.
        case 0xb4:
          break;
        case 0xb3:
          break;
        case 0xb2:
          final index = ((w0 & 0xffff) ~/ 2).clamp(0, 79), v = vertices[index];
          if (v != null && ((w0 >> 16) & 255) == 0x10) {
            vertices[index] = N64Vertex(v.clip, rgba(w1), v.s, v.t);
          }
        case 0xe4:
        case 0xe5:
          final st = u(pc + 4, 4), delta = u(pc + 12, 4);
          pc += 16;
          textureRect(w0, w1, st, delta, op == 0xe5);
        default:
          if (op >= 0xe6) {
            rdp(w0, w1);
          } else {
            throw UnsupportedError('RSP GBI opcode 0x${op.toRadixString(16)}');
          }
      }
    }
    throw StateError('RSP display list exceeded command budget');
  }

  void drawIndices(int word, int divisor) {
    if (!rasterize) return;
    final indices = [(word >> 16) & 255, (word >> 8) & 255, word & 255]
        .map((v) => v ~/ divisor)
        .toList();
    if (indices.any((i) => i >= vertices.length || vertices[i] == null)) {
      throw StateError('RSP triangle uses unloaded vertex');
    }
    var polygon = indices.map((i) => vertices[i]!).toList();
    for (var plane = 0; plane < 6; plane++) {
      double distance(N64Vertex v) =>
          v.clip[3] + (plane.isEven ? v.clip[plane ~/ 2] : -v.clip[plane ~/ 2]);
      final output = <N64Vertex>[];
      for (var i = 0; i < polygon.length; i++) {
        final a = polygon[i], b = polygon[(i + 1) % polygon.length];
        final da = distance(a), db = distance(b);
        if (da >= 0) output.add(a);
        if ((da >= 0) != (db >= 0)) output.add(a.mix(b, da / (da - db)));
      }
      polygon = output;
      if (polygon.length < 3) return;
    }
    for (var i = 1; i + 1 < polygon.length; i++) {
      triangle(polygon[0], polygon[i], polygon[i + 1]);
    }
  }

  Float64List get depth => depths.putIfAbsent(zImage,
      () => Float64List(640 * 576)..fillRange(0, 640 * 576, double.infinity));
  void triangle(N64Vertex a, N64Vertex b, N64Vertex c) {
    if (!rasterize) return;
    if ([a, b, c].any((v) => v.clip[3].abs() < 1e-9)) return;
    final vs = [a, b, c];
    final x =
        vs.map((v) => v.clip[0] / v.clip[3] * scale[0] + translate[0]).toList();
    final y = vs
        .map((v) => -v.clip[1] / v.clip[3] * scale[1] + translate[1])
        .toList();
    final z =
        vs.map((v) => v.clip[2] / v.clip[3] * scale[2] + translate[2]).toList();
    double edge(
            double ax, double ay, double bx, double by, double px, double py) =>
        (px - ax) * (by - ay) - (py - ay) * (bx - ax);
    final area = edge(x[0], y[0], x[1], y[1], x[2], y[2]);
    if (area.abs() < 1e-8) return;
    if (((geometry & 0x2000) != 0 && area < 0) ||
        ((geometry & 0x1000) != 0 && area > 0)) {
      return;
    }
    triangles++;
    final minX = math.max(scLeft, x.reduce(math.min).floor()),
        maxX =
            math.min(math.min(scRight, width) - 1, x.reduce(math.max).ceil());
    final minY = math.max(scTop, y.reduce(math.min).floor()),
        maxY = math.min(math.min(scBottom, 576) - 1, y.reduce(math.max).ceil());
    final inverse = vs.map((v) => 1 / v.clip[3]).toList();
    final depthBuffer = depth;
    final waStep = (y[2] - y[1]) / area,
        wbStep = (y[0] - y[2]) / area,
        wcStep = -waStep - wbStep;
    double delta(double va, double vb, double vc) =>
        waStep * va + wbStep * vb + wcStep * vc;
    final zStep = delta(z[0], z[1], z[2]);
    final redStep = delta(a.color[0], b.color[0], c.color[0]),
        greenStep = delta(a.color[1], b.color[1], c.color[1]),
        blueStep = delta(a.color[2], b.color[2], c.color[2]),
        alphaStep = delta(a.color[3], b.color[3], c.color[3]);
    final sa = a.s * inverse[0],
        sb = b.s * inverse[1],
        sc = c.s * inverse[2],
        ta = a.t * inverse[0],
        tb = b.t * inverse[1],
        tc = c.t * inverse[2];
    final sStep = delta(sa, sb, sc),
        tStep = delta(ta, tb, tc),
        inverseStep = delta(inverse[0], inverse[1], inverse[2]);
    for (var py = minY; py <= maxY; py++) {
      var wa = edge(x[1], y[1], x[2], y[2], minX + 0.5, py + 0.5) / area,
          wb = edge(x[2], y[2], x[0], y[0], minX + 0.5, py + 0.5) / area;
      final wc = 1 - wa - wb;
      var dz = wa * z[0] + wb * z[1] + wc * z[2],
          red = wa * a.color[0] + wb * b.color[0] + wc * c.color[0],
          green = wa * a.color[1] + wb * b.color[1] + wc * c.color[1],
          blue = wa * a.color[2] + wb * b.color[2] + wc * c.color[2],
          alpha = wa * a.color[3] + wb * b.color[3] + wc * c.color[3],
          ss = wa * sa + wb * sb + wc * sc,
          tt = wa * ta + wb * tb + wc * tc,
          divisor = wa * inverse[0] + wb * inverse[1] + wc * inverse[2];
      for (var px = minX;
          px <= maxX;
          px++,
          wa += waStep,
          wb += wbStep,
          dz += zStep,
          red += redStep,
          green += greenStep,
          blue += blueStep,
          alpha += alphaStep,
          ss += sStep,
          tt += tStep,
          divisor += inverseStep) {
        // Re-evaluate coverage near an edge: accumulated roundoff must not
        // introduce cracks in adjacent triangles sharing that edge.
        var inside = wa >= 0 && wb >= 0 && 1 - wa - wb >= 0;
        if (wa.abs() < 1e-10 ||
            wb.abs() < 1e-10 ||
            (1 - wa - wb).abs() < 1e-10) {
          final exactA =
                  edge(x[1], y[1], x[2], y[2], px + 0.5, py + 0.5) / area,
              exactB = edge(x[2], y[2], x[0], y[0], px + 0.5, py + 0.5) / area;
          inside = exactA >= 0 && exactB >= 0 && 1 - exactA - exactB >= 0;
        }
        if (!inside) continue;
        final at = py * width + px;
        if ((geometry & 1) != 0 &&
            (otherLow & 0x10) != 0 &&
            dz > depthBuffer[at]) {
          continue;
        }
        if ((geometry & 1) != 0 && (otherLow & 0x20) != 0) depthBuffer[at] = dz;
        _shade[0] = red;
        _shade[1] = green;
        _shade[2] = blue;
        _shade[3] = alpha;
        pixel(
            px,
            py,
            _combine(
                _shade,
                textureOn
                    ? _texel(activeTile, ss / divisor, tt / divisor)
                    : _white));
      }
    }
  }

  List<double> rgba(int v) =>
      List.generate(4, (i) => ((v >> ((3 - i) * 8)) & 255).toDouble());
  List<double> rgba16(int v) => [
        ((v >> 11) & 31) * 255 / 31,
        ((v >> 6) & 31) * 255 / 31,
        ((v >> 1) & 31) * 255 / 31,
        (v & 1) * 255.0
      ];

  /// Public inspection returns a snapshot; the rasterizer uses private scratch.
  List<double> texel(int index, double s, double t) =>
      List<double>.of(_texel(index, s, t));
  List<double> combine(List<double> shade, List<double> texture) =>
      List<double>.of(_combine(shade, texture));

  List<double> _texel(int index, double s, double t) {
    final tile = tiles[index];
    int coordinate(
        double value, double low, double high, int shift, int mode, int mask) {
      value = shift <= 10 ? value / (1 << shift) : value * (1 << (16 - shift));
      var coord = (value - low).floor(), extent = (high - low).floor();
      if ((mode & 2) != 0) coord = coord.clamp(0, math.max(0, extent));
      if (mask != 0) {
        final period = 1 << mask;
        if ((mode & 1) != 0 && (coord & period) != 0) {
          coord = period - 1 - (coord & (period - 1));
        } else {
          coord &= period - 1;
        }
      }
      return coord;
    }

    final x = coordinate(
            s, tile.left, tile.right, tile.sShift, tile.sMode, tile.sMask),
        y = coordinate(
            t, tile.top, tile.bottom, tile.tShift, tile.tMode, tile.tMask);
    final row = tile.line * 8;
    final offset =
        (tile.tmem * 8 + y * row + ((x * (4 << tile.size)) ~/ 8)) & 4095;
    var v = tmem[offset];
    if (tile.size == 0) v = (x.isEven ? v >> 4 : v) & 15;
    if (tile.size >= 2) v = (v << 8) | tmem[(offset + 1) & 4095];
    if (tile.size == 3) {
      v = (v << 16) |
          (tmem[(offset + 2) & 4095] << 8) |
          tmem[(offset + 3) & 4095];
    }
    if (tile.format == 0) {
      return tile.size == 3
          ? _textureRgba(
              ((v >> 24) & 255).toDouble(),
              ((v >> 16) & 255).toDouble(),
              ((v >> 8) & 255).toDouble(),
              (v & 255).toDouble())
          : _texture16(v);
    }
    if (tile.format == 2) {
      final paletteIndex = tile.size == 0 ? tile.palette * 16 + v : v;
      final p = (2048 + paletteIndex * 8) & 4095;
      return _texture16((tmem[p] << 8) | tmem[p + 1]);
    }
    if (tile.format == 3) {
      if (tile.size == 2) {
        final intensity = (v >> 8).toDouble();
        return _textureRgba(
            intensity, intensity, intensity, (v & 255).toDouble());
      }
      final intensity =
              tile.size == 1 ? (v >> 4) * 17 : ((v >> 1) & 7) * 255 / 7,
          alpha = tile.size == 1 ? (v & 15) * 17 : (v & 1) * 255;
      return _textureRgba(intensity.toDouble(), intensity.toDouble(),
          intensity.toDouble(), alpha.toDouble());
    }
    final intensity = tile.size == 0 ? v * 17 : v;
    return _textureRgba(intensity.toDouble(), intensity.toDouble(),
        intensity.toDouble(), intensity.toDouble());
  }

  List<double> _combine(List<double> shade, List<double> texture) {
    if (((otherHigh >> 20) & 3) == 2) return texture;
    final combined = _combined..fillRange(0, 4, 0);
    for (var cycle = 0;
        cycle < (((otherHigh >> 20) & 3) == 1 ? 2 : 1);
        cycle++) {
      final a = cycle == 0 ? (combine0 >> 20) & 15 : (combine0 >> 5) & 15;
      final b = cycle == 0 ? (combine1 >> 28) & 15 : (combine1 >> 24) & 15;
      final cc = cycle == 0 ? (combine0 >> 15) & 31 : combine0 & 31;
      final d = cycle == 0 ? (combine1 >> 15) & 7 : (combine1 >> 6) & 7;
      final aa = cycle == 0 ? (combine0 >> 12) & 7 : (combine1 >> 21) & 7;
      final ab = cycle == 0 ? (combine1 >> 12) & 7 : (combine1 >> 3) & 7;
      final ac = cycle == 0 ? (combine0 >> 9) & 7 : (combine1 >> 18) & 7;
      final ad = cycle == 0 ? (combine1 >> 9) & 7 : combine1 & 7;
      double rgb(int selector, int channel, int slot) {
        if (slot == 2 && selector >= 7) {
          if (selector == 7) return combined[3];
          if (selector == 8 || selector == 9) return texture[3];
          if (selector == 10) return primitive[3];
          if (selector == 11) return shade[3];
          if (selector == 12) return environment[3];
          return 0;
        }
        if (selector == 0) return combined[channel];
        if (selector == 1 || selector == 2) return texture[channel];
        if (selector == 3) return primitive[channel];
        if (selector == 4) return shade[channel];
        if (selector == 5) return environment[channel];
        if (selector == 6 && (slot == 0 || slot == 3)) return 255;
        return 0;
      }

      double alpha(int selector) => switch (selector) {
            0 => combined[3],
            1 || 2 => texture[3],
            3 => primitive[3],
            4 => shade[3],
            5 => environment[3],
            6 => 255,
            _ => 0
          };
      for (var i = 0; i < 3; i++) {
        combined[i] =
            ((rgb(a, i, 0) - rgb(b, i, 1)) * rgb(cc, i, 2) / 255 + rgb(d, i, 3))
                .clamp(0, 255)
                .toDouble();
      }
      combined[3] = ((alpha(aa) - alpha(ab)) * alpha(ac) / 255 + alpha(ad))
          .clamp(0, 255)
          .toDouble();
    }
    return combined;
  }

  void pixel(int x, int y, List<double> color) {
    if (x < scLeft ||
        x >= scRight ||
        x < 0 ||
        x >= width ||
        y < scTop ||
        y >= scBottom ||
        y < 0 ||
        y >= 576) {
      return;
    }
    if (color[3] < 1) return;
    final size = colorSize == 3 ? 4 : 2,
        at = colorImage + (y * width + x) * size;
    if (at + size > bus.ram.length) return;
    var redValue = color[0], greenValue = color[1], blueValue = color[2];
    if ((otherLow & 0x4000) != 0 && color[3] < 255) {
      final old = u(at, size), alpha = color[3] / 255, inverse = 1 - alpha;
      final oldRed = size == 4
              ? ((old >> 24) & 255).toDouble()
              : _fiveBit[(old >> 11) & 31],
          oldGreen = size == 4
              ? ((old >> 16) & 255).toDouble()
              : _fiveBit[(old >> 6) & 31],
          oldBlue = size == 4
              ? ((old >> 8) & 255).toDouble()
              : _fiveBit[(old >> 1) & 31];
      redValue = redValue * alpha + oldRed * inverse;
      greenValue = greenValue * alpha + oldGreen * inverse;
      blueValue = blueValue * alpha + oldBlue * inverse;
    }
    final red = redValue.round().clamp(0, 255),
        green = greenValue.round().clamp(0, 255),
        blue = blueValue.round().clamp(0, 255);
    bus.ramWrite(
        at,
        size == 4
            ? (red << 24) | (green << 16) | (blue << 8) | 255
            : ((red >> 3) << 11) | ((green >> 3) << 6) | ((blue >> 3) << 1) | 1,
        size);
  }

  void textureRect(int w0, int w1, int st, int delta, bool flip) {
    if (!rasterize) return;
    final left = ((w1 >> 12) & 4095) / 4, top = (w1 & 4095) / 4;
    var right = ((w0 >> 12) & 4095) / 4, bottom = (w0 & 4095) / 4;
    final tile = (w1 >> 24) & 7, cycle = (otherHigh >> 20) & 3;
    if (cycle >= 2) {
      right++;
      bottom++;
    }
    final s = (st >> 16).toSigned(16) / 32, t = (st & 65535).toSigned(16) / 32;
    final ds = (delta >> 16).toSigned(16) / 1024 / (cycle == 2 ? 4 : 1),
        dt = (delta & 65535).toSigned(16) / 1024;
    for (var y = math.max(scTop, top.ceil());
        y < math.min(scBottom, bottom.ceil());
        y++) {
      for (var x = math.max(scLeft, left.ceil());
          x < math.min(scRight, right.ceil());
          x++) {
        final tex = _texel(tile, s + (flip ? y - top : x - left) * ds,
            t + (flip ? x - left : y - top) * dt);
        pixel(x, y, _combine(_white, tex));
      }
    }
  }

  void rdp(int w0, int w1) {
    final op = w0 >> 24;
    switch (op) {
      case 0xff:
        colorImage = resolve(w1);
        colorSize = (w0 >> 19) & 3;
        width = (w0 & 4095) + 1;
      case 0xfe:
        zImage = resolve(w1);
      case 0xfd:
        textureImage = resolve(w1);
        textureSize = (w0 >> 19) & 3;
        textureWidth = (w0 & 4095) + 1;
        textureFormat = (w0 >> 21) & 7;
      case 0xfc:
        combine0 = w0 & 0xffffff;
        combine1 = w1;
      case 0xfa:
        primitive = rgba(w1);
      case 0xfb:
        environment = rgba(w1);
      case 0xf8:
        fog = rgba(w1);
      case 0xf7:
        fillColor = w1;
      case 0xf6:
        if (!rasterize) break;
        final x0 = (w1 >> 12) & 4095,
            y0 = w1 & 4095,
            x1 = (w0 >> 12) & 4095,
            y1 = w0 & 4095;
        if (colorImage == zImage) {
          depth.fillRange(0, depth.length, double.infinity);
          break;
        }
        for (var y = math.max(scTop, y0 ~/ 4);
            y <= math.min(scBottom - 1, y1 ~/ 4);
            y++) {
          for (var x = math.max(scLeft, x0 ~/ 4);
              x <= math.min(math.min(scRight, width) - 1, x1 ~/ 4);
              x++) {
            if (((otherHigh >> 20) & 3) == 3) {
              final size = colorSize == 3 ? 4 : 2,
                  at = colorImage + (y * width + x) * size;
              if (at + size <= bus.ram.length) {
                bus.ramWrite(
                    at,
                    size == 4
                        ? fillColor
                        : (x.isEven ? fillColor >> 16 : fillColor & 65535),
                    size);
              }
            } else {
              pixel(x, y, _combine(_white, _white));
            }
          }
        }
      case 0xf5:
        final tile = tiles[(w1 >> 24) & 7];
        tile.format = (w0 >> 21) & 7;
        tile.size = (w0 >> 19) & 3;
        tile.line = (w0 >> 9) & 511;
        tile.tmem = w0 & 511;
        tile.palette = (w1 >> 20) & 15;
        tile.tMode = (w1 >> 18) & 3;
        tile.tMask = (w1 >> 14) & 15;
        tile.tShift = (w1 >> 10) & 15;
        tile.sMode = (w1 >> 8) & 3;
        tile.sMask = (w1 >> 4) & 15;
        tile.sShift = w1 & 15;
      case 0xf2:
        final tile = tiles[(w1 >> 24) & 7];
        tile.left = ((w0 >> 12) & 4095) / 4;
        tile.top = (w0 & 4095) / 4;
        tile.right = ((w1 >> 12) & 4095) / 4;
        tile.bottom = (w1 & 4095) / 4;
      case 0xf3:
        final tile = tiles[(w1 >> 24) & 7], count = ((w1 >> 12) & 4095) + 1;
        final bytes = (count * (4 << textureSize) + 7) ~/ 8;
        final start = textureImage +
            ((((w0 & 4095) ~/ 4) * textureWidth + (((w0 >> 12) & 4095) ~/ 4)) *
                    (4 << textureSize)) ~/
                8;
        for (var i = 0; i < bytes; i++) {
          tmem[(tile.tmem * 8 + i) & 4095] = u(start + i, 1);
        }
      case 0xf4:
        final tile = tiles[(w1 >> 24) & 7],
            x0 = ((w0 >> 12) & 4095) ~/ 4,
            y0 = (w0 & 4095) ~/ 4,
            x1 = ((w1 >> 12) & 4095) ~/ 4,
            y1 = (w1 & 4095) ~/ 4;
        final bytes = ((x1 - x0 + 1) * (4 << textureSize) + 7) ~/ 8;
        for (var y = y0; y <= y1; y++) {
          for (var i = 0; i < bytes; i++) {
            tmem[(tile.tmem * 8 + (y - y0) * tile.line * 8 + i) & 4095] = u(
                textureImage +
                    ((y * textureWidth + x0) * (4 << textureSize)) ~/ 8 +
                    i,
                1);
          }
        }
      case 0xf0:
        final tile = tiles[(w1 >> 24) & 7], count = ((w1 >> 14) & 1023) + 1;
        for (var i = 0; i < count; i++) {
          for (var j = 0; j < 8; j++) {
            tmem[(tile.tmem * 8 + i * 8 + j) & 4095] =
                u(textureImage + i * 2 + (j & 1), 1);
          }
        }
      case 0xed:
        scLeft = ((w0 >> 12) & 4095) ~/ 4;
        scTop = (w0 & 4095) ~/ 4;
        scRight = ((w1 >> 12) & 4095) ~/ 4;
        scBottom = (w1 & 4095) ~/ 4;
      case 0xef:
        otherHigh = w0 & 0xffffff;
        otherLow = w1;
      case 0xe9:
        bus.interrupt(32);
      case 0xe6:
      case 0xe7:
      case 0xe8:
      case 0xee:
      case 0xec:
      case 0xeb:
      case 0xea:
      case 0xf9:
        break;
      default:
        throw UnsupportedError('RDP opcode 0x${op.toRadixString(16)}');
    }
  }

  void commands(int start, int end) {
    if ((bus.dp[3] & 1) != 0) throw UnsupportedError('RDP XBUS command source');
    for (var at = start; at < end; at += 8) {
      rdp(u(at, 4) | 0xc0000000, u(at + 4, 4));
    }
  }
}
