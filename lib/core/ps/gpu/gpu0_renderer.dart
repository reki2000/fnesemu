part of 'gpu.dart';

extension Gp0Renderer on Gpu {
  static const xMask = 0x3ff;
  static const yMask = 0x1ff;

  (Point p0, Point p1, Point p2) sortVertice(
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

  bool renderLine(int cmd, int v0, int v1) {
    final c15 = Color.ofC24(cmd).c15;
    final p0 = Point.of(v0, 0, 0);
    final p1 = Point.of(v1, 0, 0);

    if (abs(p1.y - p0.y) < abs(p1.x - p0.x)) {
      // x loop
      final dx = (p1.x < p0.x) ? -1 : 1;
      for (int x = p0.x; x != p1.x; x += dx) {
        final p01 = p0.mixX(p1, x);
        pset16(x, p01.y, c15);
      }
    } else {
      // y loop
      final dy = (p1.y < p0.y) ? -1 : 1;
      for (int y = p0.y; y != p1.y; y += dy) {
        final p01 = p0.mixY(p1, y);
        pset16(p01.x, y, c15);
      }
    }

    return true;
  }

  bool renderGouraudLine(int cmd, int v0, int v1, int c0, int c1) {
    final p0 = Point.of(v0, c0, 0);
    final p1 = Point.of(v1, c1, 0);

    if (abs(p1.y - p0.y) < abs(p1.x - p0.x)) {
      // x loop
      final dx = (p1.x < p0.x) ? -1 : 1;
      for (int x = p0.x; x != p1.x; x += dx) {
        final p01 = p0.mixX(p1, x);
        pset16(x, p01.y, p01.c.c15);
      }
    } else {
      // y loop
      final dy = (p1.y < p0.y) ? -1 : 1;
      for (int y = p0.y; y != p1.y; y += dy) {
        final p01 = p0.mixY(p1, y);
        pset16(p01.x, y, p01.c.c15);
      }
    }
    return true;
  }

  bool renderFlatPolygon(int cmd, int v0, int v1, int v2) {
    final c24 = Color.ofC24(cmd).c24;
    final (p0, p1, p2) = sortVertice(v0, v1, v2, 0, 0, 0, 0, 0, 0);
    final transparent = cmd.bit25;

    // debugLog(
    //     'GPU0: renderFlat (${p0.x},${p0.y}), (${p1.x},${p1.y}), (${p2.x},${p2.y})');

    for (int y = p0.y; y <= p2.y; y++) {
      final p012 = y >= p1.y ? p1.mixY(p2, y) : p0.mixY(p1, y);
      final p02 = p0.mixY(p2, y);

      final (left, right) = p012.x > p02.x ? (p02, p012) : (p012, p02);
      for (int x = left.x; x < right.x; x++) {
        pset24(x, y, c24, transparent: transparent);
      }
    }

    return true;
  }

  bool renderGouraudPolygon(
      int cmd, int c0, int v0, int c1, int v1, int c2, int v2) {
    final (p0, p1, p2) = sortVertice(v0, v1, v2, c0, c1, c2, 0, 0, 0);
    final transparent = cmd.bit25;

    // debugLog(
    //     'GPU0:renderGouraud (${p0.x},${p0.y}:${p0.c.c24.hex32}), (${p1.x},${p1.y}:${p1.c.c24.hex32}), (${p2.x},${p2.y}:${p2.c.c24.hex32}) '
    //     'offset:$drawingOffsetX,$drawingOffsetY area:$drawingX1,$drawingY1-$drawingX2,$drawingY2 ');

    for (int y = p0.y; y <= p2.y; y++) {
      final p012 = y >= p1.y ? p1.mixY(p2, y) : p0.mixY(p1, y);
      final p02 = p0.mixY(p2, y);

      final (left, right) = p012.x > p02.x ? (p02, p012) : (p012, p02);
      for (int x = left.x; x < right.x; x++) {
        final c = left.c.mix(right.c, x - left.x, right.x - left.x);
        pset24(x, y, c.c24, transparent: transparent);
      }
    }

    return true;
  }

  bool renderTexturedGouraudPolygon(int cmd, int clut, int page, int c0, int v0,
      int t0, int c1, int v1, int t1, int c2, int v2, int t2) {
    final (p0, p1, p2) = sortVertice(v0, v1, v2, c0, c1, c2, t0, t1, t2);
    final modulated = !cmd.bit24;
    final modulateColor = Color.ofC24(cmd);
    final transparentMask = cmd.bit25 ? 0xffff : 0x7fff;
    final gouraud = cmd.bit28;

    // debugLog(
    //     'GPU0: renderTextured (${p0.x},${p0.y},${p0.u},${p0.v}), (${p1.x},${p1.y},${p1.u},${p1.v}), (${p2.x},${p2.y},${p2.u},${p2.v})');

    for (int y = p0.y; y <= p2.y; y++) {
      final p012 = y >= p1.y ? p1.mixY(p2, y) : p0.mixY(p1, y);
      final p02 = p0.mixY(p2, y);

      final (left, right) = p012.x > p02.x ? (p02, p012) : (p012, p02);
      for (int x = left.x; x < right.x; x++) {
        final uv = left.mix(right, x - left.x, right.x - left.x);
        final texColor =
            getTextureColor(uv.u, uv.v, clut, page) & transparentMask;
        final c16 = modulated
            ? modulate(texColor, gouraud ? uv.c : modulateColor)
            : texColor;
        if (texColor != 0) {
          pset16(x, y, c16);
        }
      }
    }

    return true;
  }
}
