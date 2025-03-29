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

  bool renderFlatPolygon(int cmd, int v0, int v1, int v2) {
    final c15 = Color.ofC24(cmd).c15;
    final (p0, p1, p2) = sortVertice(v0, v1, v2, 0, 0, 0, 0, 0, 0);

    // debugLog(
    //     'GPU0: renderFlat (${p0.x},${p0.y}), (${p1.x},${p1.y}), (${p2.x},${p2.y})');

    for (int y = p0.y; y <= p2.y; y++) {
      final p012 = y >= p1.y ? p1.mixY(p2, y) : p0.mixY(p1, y);
      final p02 = p0.mixY(p2, y);

      final (left, right) = p012.x > p02.x ? (p02, p012) : (p012, p02);
      for (int x = left.x; x < right.x; x++) {
        pset16(x, y, c15);
      }
    }

    return true;
  }

  bool renderGouraudPolygon(
      int cmd, int c0, int v0, int c1, int v1, int c2, int v2) {
    final (p0, p1, p2) = sortVertice(v0, v1, v2, c0, c1, c2, 0, 0, 0);

    // debugLog(
    //     'GPU0: renderGouraud (${p0.x},${p0.y}), (${p1.x},${p1.y}), (${p2.x},${p2.y})');

    for (int y = p0.y; y <= p2.y; y++) {
      final p012 = y >= p1.y ? p1.mixY(p2, y) : p0.mixY(p1, y);
      final p02 = p0.mixY(p2, y);

      final (left, right) = p012.x > p02.x ? (p02, p012) : (p012, p02);
      for (int x = left.x; x < right.x; x++) {
        final c = left.c.mix(right.c, x - left.x, right.x - left.x);
        pset16(x, y, c.c15);
      }
    }

    return true;
  }

  bool renderTexturedPolygon(int cmd, int clut, int page, int v0, int t0,
      int v1, int t1, int v2, int t2) {
    final (p0, p1, p2) = sortVertice(v0, v1, v2, 0, 0, 0, t0, t1, t2);

    // debugLog(
    //     'GPU0: renderTextured (${p0.x},${p0.y},${p0.u},${p0.v}), (${p1.x},${p1.y},${p1.u},${p1.v}), (${p2.x},${p2.y},${p2.u},${p2.v})');

    for (int y = p0.y; y <= p2.y; y++) {
      final p012 = y >= p1.y ? p1.mixY(p2, y) : p0.mixY(p1, y);
      final p02 = p0.mixY(p2, y);

      final (left, right) = p012.x > p02.x ? (p02, p012) : (p012, p02);
      for (int x = left.x; x < right.x; x++) {
        final uv = left.mix(right, x - left.x, right.x - left.x);
        final c = getTextureColor(uv.u, uv.v, clut, page);
        if (c != 0) {
          pset16(x, y, c);
        }
      }
    }

    return true;
  }

  bool renderTexturedGouraudPolygon(
      int cmd, c0, p0, t0, c1, p1, t1, c2, p2, t2) {
    debugLog('GP0: renderTexturedGouraudPolygon umimplemented');
    return true;
  }
}
