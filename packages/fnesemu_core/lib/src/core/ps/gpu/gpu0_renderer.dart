part of 'gpu.dart';

/// a point on a polygon edge at a scanline, interpolated between two vertice.
/// reused for each scanline instead of allocating [Point]s and [Color]s.
class _Edge {
  int x = 0, u = 0, v = 0, r = 0, g = 0, b = 0;

  /// same as `p.mixY(q, y)`: rounds to the nearest, [p] if p.y == q.y
  @pragma('vm:prefer-inline')
  void at(Point p, Point q, int y) {
    final dy = y - p.y;
    final part = dy < 0 ? -dy : dy;
    final dt = q.y - p.y;
    final total = dt < 0 ? -dt : dt;
    final ac = p.c, bc = q.c;
    if (total == 0) {
      x = p.x;
      u = p.u;
      v = p.v;
      r = ac.r;
      g = ac.g;
      b = ac.b;
      return;
    }
    final half = total ~/ 2;
    final rest = total - part;
    x = (p.x * rest + q.x * part + half) ~/ total;
    u = (p.u * rest + q.u * part + half) ~/ total;
    v = (p.v * rest + q.v * part + half) ~/ total;
    r = (ac.r * rest + bc.r * part + half) ~/ total;
    g = (ac.g * rest + bc.g * part + half) ~/ total;
    b = (ac.b * rest + bc.b * part + half) ~/ total;
  }

  /// only the x of [at]
  @pragma('vm:prefer-inline')
  void atX(Point a, Point b, int y) {
    final dy = y - a.y;
    final part = dy < 0 ? -dy : dy;
    final dt = b.y - a.y;
    final total = dt < 0 ? -dt : dt;
    x = total == 0
        ? a.x
        : (a.x * (total - part) + b.x * part + total ~/ 2) ~/ total;
  }
}

extension Gp0Renderer on Gpu {
  static const xMask = 0x3ff;
  static const yMask = 0x1ff;

  (Point, Point, Point) sortVertice2(Point p0, Point p1, Point p2) {
    if (p1.y < p0.y) {
      (p0, p1) = (p1, p0);
    }
    if (p2.y < p1.y) {
      (p1, p2) = (p2, p1);
    }
    if (p1.y < p0.y) {
      (p0, p1) = (p1, p0);
    }

    return (p0, p1, p2);
  }

  (Point, Point, Point) sortVertice(
      int v0, int v1, int v2, int c0, int c1, int c2, int t0, int t1, int t2) {
    var p0 = Point.of(v0, c0, t0);
    var p1 = Point.of(v1, c1, t1);
    var p2 = Point.of(v2, c2, t2);

    if (p1.y < p0.y) {
      (p0, p1) = (p1, p0);
    }
    if (p2.y < p1.y) {
      (p1, p2) = (p2, p1);
    }
    if (p1.y < p0.y) {
      (p0, p1) = (p1, p0);
    }

    return (p0, p1, p2);
  }

  int abs(int v) => v < 0 ? -v : v;

  // floor division rounding to the nearest
  static int _divRound(int a, int b) =>
      a >= 0 ? (a * 2 + b) ~/ (b * 2) : -((-a * 2 + b - 1) ~/ (b * 2));

  /// primitives larger than 1023x511 are not rendered
  static bool _tooLarge(Point p0, Point p1) =>
      abs_(p1.x - p0.x) >= 1024 || abs_(p1.y - p0.y) >= 512;

  static int abs_(int v) => v < 0 ? -v : v;

  bool renderLine(int cmd, int v0, int v1) =>
      _drawLine(cmd, Point.of(v0, cmd, 0), Point.of(v1, cmd, 0), false);

  bool renderGouraudLine(int cmd, int v0, int v1, int c0, int c1) =>
      _drawLine(cmd, Point.of(v0, c0, 0), Point.of(v1, c1, 0), true);

  bool _drawLine(int cmd, Point p0, Point p1, bool gouraud) {
    if (_tooLarge(p0, p1)) {
      return false;
    }

    final transparent = cmd.bit25;
    final flatC15 = p0.c.c15;
    final dx = p1.x - p0.x;
    final dy = p1.y - p0.y;
    final steps = abs_(dx).max(abs_(dy));

    // both end points are drawn
    for (int i = 0; i <= steps; i++) {
      final x = steps == 0 ? p0.x : p0.x + _divRound(dx * i, steps);
      final y = steps == 0 ? p0.y : p0.y + _divRound(dy * i, steps);
      final c15 = gouraud ? dither(x, y, p0.c.mix(p1.c, i, steps)) : flatC15;
      pset16(x, y, c15, blend: transparent);
    }

    return true;
  }

  /// the edges of the triangle at scanline [y]: p0-p1 or p1-p2 in [_e0] and
  /// p0-p2 in [_e1], only x unless [full]
  @pragma('vm:prefer-inline')
  void _span(Point p0, Point p1, Point p2, int y, bool full) {
    final e012 = _e0, e02 = _e1;
    if (full) {
      y >= p1.y ? e012.at(p1, p2, y) : e012.at(p0, p1, y);
      e02.at(p0, p2, y);
    } else {
      y >= p1.y ? e012.atX(p1, p2, y) : e012.atX(p0, p1, y);
      e02.atX(p0, p2, y);
    }
  }

  bool renderFlatPolygon(int cmd, int v0, int v1, int v2) {
    final c24 = Color.ofC24(cmd);
    final (p0, p1, p2) = sortVertice(v0, v1, v2, 0, 0, 0, 0, 0, 0);
    final transparent = cmd.bit25;
    if (_tooLarge(p0, p1) || _tooLarge(p1, p2) || _tooLarge(p0, p2)) {
      return false;
    }
    final c15 = c24.c15; // flat polygons are not dithered
    final semi = status.shr5.mask2;

    for (int y = p0.y; y < p2.y; y++) {
      _span(p0, p1, p2, y, false);
      final x012 = _e0.x, x02 = _e1.x;
      final (left, right) = x012 > x02 ? (x02, x012) : (x012, x02);
      for (int x = left; x < right; x++) {
        _plot(x, y, c15, transparent, semi);
      }
    }

    return true;
  }

  @pragma('vm:unsafe:no-bounds-checks')
  bool renderGouraudPolygon(
      int cmd, int c0, int v0, int c1, int v1, int c2, int v2) {
    final (p0, p1, p2) = sortVertice(v0, v1, v2, c0, c1, c2, 0, 0, 0);
    final transparent = cmd.bit25;
    if (_tooLarge(p0, p1) || _tooLarge(p1, p2) || _tooLarge(p0, p2)) {
      return false;
    }
    final semi = status.shr5.mask2;
    final dithering = status.bit9;

    for (int y = p0.y; y < p2.y; y++) {
      _span(p0, p1, p2, y, true);
      final swap = _e0.x > _e1.x;
      final left = swap ? _e1 : _e0;
      final right = swap ? _e0 : _e1;
      final lx = left.x, rx = right.x;
      final lr = left.r, lg = left.g, lb = left.b;
      final rr = right.r, rg = right.g, rb = right.b;
      final width = rx - lx;
      final half = width ~/ 2;
      for (int x = lx; x < rx; x++) {
        // same as left.c.mix(right.c, part, width) then dither()
        final part = x - lx;
        final rest = width - part;
        final r = (lr * rest + rr * part + half) ~/ width;
        final g = (lg * rest + rg * part + half) ~/ width;
        final b = (lb * rest + rb * part + half) ~/ width;
        final int c15;
        if (!dithering) {
          c15 = b.shl7 & 0x7c00 | g.shl2 & 0x3e0 | r.shr3.mask5;
        } else {
          final d = Gpu._ditherV[x.mask2 | y.mask2.shl2];
          c15 = Gpu._c8toC5(r + d) |
              Gpu._c8toC5(g + d).shl5 |
              Gpu._c8toC5(b + d).shl10;
        }
        _plot(x, y, c15, transparent, semi);
      }
    }

    return true;
  }

  bool renderTexturedGouraudPolygon4(List<int> c) {
    final cmd = c[0];
    final modulated = !cmd.bit24;
    final transparent = cmd.bit25;
    final gouraud = cmd.bit28;
    final rectangle = cmd.bit27;
    final modulateColor = Color.ofC24(cmd);

    final clut = c[2].shr16;
    final page = c[gouraud ? 5 : 4].shr16;

    final semiTransparent = page.shr5.mask2;

    final baseX = page.shl6 & 0x3c0;
    final baseY = page.shl4 & 0x100;
    final clutMode = page.shr7.mask2;
    final clutBase = (clut.shr6 & yMask) * 1024 + clut.mask6.shl4;

    // 0c,1xy,2uv   3c,4xy,5uv  6c,7xy,8uv   9c,10xy,11uv
    // 0c,1xy,2uv   3xy,4uv  5xy,6uv  7xy,8uv

    final p0_ = gouraud ? Point.of(c[1], c[0], c[2]) : Point.of(c[1], 0, c[2]);
    final p1_ = gouraud ? Point.of(c[4], c[3], c[5]) : Point.of(c[3], 0, c[4]);
    final p2_ = gouraud ? Point.of(c[7], c[6], c[8]) : Point.of(c[5], 0, c[6]);

    _renderTexturedTriangle(
        sortVertice2(p0_, p1_, p2_),
        modulated,
        transparent,
        gouraud,
        modulateColor,
        semiTransparent,
        baseX,
        baseY,
        clutMode,
        clutBase);

    if (rectangle) {
      final p3_ =
          gouraud ? Point.of(c[10], c[9], c[11]) : Point.of(c[7], 0, c[8]);
      _renderTexturedTriangle(
          sortVertice2(p1_, p2_, p3_),
          modulated,
          transparent,
          gouraud,
          modulateColor,
          semiTransparent,
          baseX,
          baseY,
          clutMode,
          clutBase);
    }
    return true;
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void _renderTexturedTriangle(
      (Point, Point, Point) points,
      bool modulated,
      bool transparent,
      bool gouraud,
      Color modulateColor,
      int semiTransparent,
      int baseX,
      int baseY,
      int clutMode,
      int clutBase) {
    final (p0, p1, p2) = points;
    final x1 = drawingX1 - drawingOffsetX;
    final y1 = drawingY1 - drawingOffsetY;
    final x2 = drawingX2 - drawingOffsetX;
    final y2 = drawingY2 - drawingOffsetY;

    if (p0.y > y2 ||
        p2.y < y1 ||
        (p0.x < x1 && p1.x < x1 && p2.x < x1) ||
        (p0.x > x2 && p1.x > x2 && p2.x > x2) ||
        _tooLarge(p0, p1) ||
        _tooLarge(p1, p2) ||
        _tooLarge(p0, p2)) {
      return;
    }

    final dithering = status.bit9;
    final mr = modulateColor.r, mg = modulateColor.g, mb = modulateColor.b;

    for (int y = p0.y; y < p2.y; y++) {
      _span(p0, p1, p2, y, true);
      final swap = _e0.x > _e1.x;
      final left = swap ? _e1 : _e0;
      final right = swap ? _e0 : _e1;
      final lx = left.x, rx = right.x;
      final lu = left.u, lv = left.v, ru = right.u, rv = right.v;
      final lr = left.r, lg = left.g, lb = left.b;
      final rr = right.r, rg = right.g, rb = right.b;
      final width = rx - lx;
      final half = width ~/ 2;
      final dy = y.mask2.shl2;

      for (int x = lx; x < rx; x++) {
        final part = x - lx;
        final rest = width - part;
        final u = (lu * rest + ru * part) ~/ width;
        final v = (lv * rest + rv * part) ~/ width;
        final texColor =
            getTextureColor2(u, v, baseX, baseY, clutBase, clutMode);
        if (texColor != 0) {
          int c16 = texColor;
          if (modulated) {
            // same as ditherAndModulate(x, y, texColor, color)
            final int r, g, b;
            if (gouraud) {
              r = (lr * rest + rr * part + half) ~/ width;
              g = (lg * rest + rg * part + half) ~/ width;
              b = (lb * rest + rb * part + half) ~/ width;
            } else {
              r = mr;
              g = mg;
              b = mb;
            }
            final d = dithering ? Gpu._ditherV[x.mask2 | dy] : 0;
            c16 = Gpu._c8toC5((texColor.mask5 * r).shr4 + d) |
                Gpu._c8toC5((texColor.shr5.mask5 * g).shr4 + d).shl5 |
                Gpu._c8toC5((texColor.shr10.mask5 * b).shr4 + d).shl10 |
                texColor & 0x8000;
          }
          _plot(x, y, c16, transparent && texColor.bit15, semiTransparent);
        }
      }
    }
  }
}
