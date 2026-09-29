part of 'gpu.dart';

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

  bool renderFlatPolygon(int cmd, int v0, int v1, int v2) {
    final c24 = Color.ofC24(cmd);
    final (p0, p1, p2) = sortVertice(v0, v1, v2, 0, 0, 0, 0, 0, 0);
    final transparent = cmd.bit25;
    if (_tooLarge(p0, p1) || _tooLarge(p1, p2) || _tooLarge(p0, p2)) {
      return false;
    }
    final c15 = c24.c15; // flat polygons are not dithered

    // debugLog(
    //     'GPU0: renderFlat (${p0.x},${p0.y}), (${p1.x},${p1.y}), (${p2.x},${p2.y})');

    for (int y = p0.y; y < p2.y; y++) {
      final p012 = y >= p1.y ? p1.mixY(p2, y) : p0.mixY(p1, y);
      final p02 = p0.mixY(p2, y);

      final (left, right) = p012.x > p02.x ? (p02, p012) : (p012, p02);
      for (int x = left.x; x < right.x; x++) {
        pset16(x, y, c15, blend: transparent);
      }
    }

    return true;
  }

  bool renderGouraudPolygon(
      int cmd, int c0, int v0, int c1, int v1, int c2, int v2) {
    final (p0, p1, p2) = sortVertice(v0, v1, v2, c0, c1, c2, 0, 0, 0);
    final transparent = cmd.bit25;
    if (_tooLarge(p0, p1) || _tooLarge(p1, p2) || _tooLarge(p0, p2)) {
      return false;
    }

    // debugLog(
    //     'gp0: drawPolygon: ${dumpCmd()} (${p0.x},${p0.y}:${p0.c.c24.x8}), (${p1.x},${p1.y}:${p1.c.c24.x8}), (${p2.x},${p2.y}:${p2.c.c24.x8}) '
    //     'offset:$drawingOffsetX,$drawingOffsetY area:$drawingX1,$drawingY1-$drawingX2,$drawingY2 ');

    for (int y = p0.y; y < p2.y; y++) {
      final p012 = y >= p1.y ? p1.mixY(p2, y) : p0.mixY(p1, y);
      final p02 = p0.mixY(p2, y);

      final (left, right) = p012.x > p02.x ? (p02, p012) : (p012, p02);
      for (int x = left.x; x < right.x; x++) {
        final c = left.c.mix(right.c, x - left.x, right.x - left.x);
        pset16(x, y, dither(x, y, c), blend: transparent);
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

    final semiTransparent = page.shr5 & 0x03;

    final baseX = page.shl6 & 0x3c0;
    final baseY = page.shl4 & 0x100;
    final clutMode = page.shr7 & 3;
    final clutBase = (clut.shr6 & yMask) * 1024 + (clut & 0x3f).shl4;

    // 0c,1xy,2uv   3c,4xy,5uv  6c,7xy,8uv   9c,10xy,11uv
    // 0c,1xy,2uv   3xy,4uv  5xy,6uv  7xy,8uv

    final p0_ = gouraud ? Point.of(c[1], c[0], c[2]) : Point.of(c[1], 0, c[2]);
    final p1_ = gouraud ? Point.of(c[4], c[3], c[5]) : Point.of(c[3], 0, c[4]);
    final p2_ = gouraud ? Point.of(c[7], c[6], c[8]) : Point.of(c[5], 0, c[6]);
    final polygons = [sortVertice2(p0_, p1_, p2_)];

    if (rectangle) {
      final p3_ =
          gouraud ? Point.of(c[10], c[9], c[11]) : Point.of(c[7], 0, c[8]);
      polygons.add(sortVertice2(p1_, p2_, p3_));
      // debugLog(
      //     "gp0: vram(0,0): ${readFrameBuffer16(0, 100).x4} ${readFrameBuffer16(320, 100).x4} forceBit15:${status.bit11} writeMask:${status.bit12}");
      // debugLog("gp0: drawPolygonTex4: $debugCmdIndexInFrame ${dumpCmd()} "
      //     "${cmd.bit25 ? "semi:$semiTransparent" : "opaq"} mod:${modulated ? cmd.x6 : "-"} "
      //     "xy(${p0_.x},${p0_.y})-(${p1_.x},${p1_.y})-(${p2_.x},${p2_.y})-(${p3_.x},${p3_.y}) "
      //     "->(${p0_.x + drawingOffsetX},${p0_.y + drawingOffsetY})-(${p1_.x + drawingOffsetX},${p1_.y + drawingOffsetY})-(${p2_.x + drawingOffsetX},${p2_.y + drawingOffsetY})-(${p3_.x + drawingOffsetX},${p3_.y + drawingOffsetY}) "
      //     "c${[4, 8, 15, 16][clutMode]} page:${status.x4} "
      //     "uv(${p0_.u}, ${p0_.v})-(${p1_.u},${p1_.v})-(${p2_.u},${p2_.v})-(${p3_.u},${p3_.v}) "
      //     "->(${p0_.u + baseX},${p0_.v + baseY})-(${p1_.u + baseX},${p1_.v + baseY})-(${p2_.u + baseX},${p2_.v + baseY})-(${p3_.u + baseX},${p3_.v + baseY}) "
      //     "(+$textureOffsetX/${textureMaskX.x2},+$textureOffsetY/${textureMaskY.x2}) "
      //     "${!clutMode.bit1 ? "clut:${clut.x4} ${clut << 4 & 0x3f0},${clut >> 6 & 0x1ff} ${dumpClut(clut, status)} " : ""}");
    } else {
      // debugLog("gp0: drawPolygonTex: ${dumpCmd()} "
      //     "${cmd.bit25 ? "semi:$semiTransparent" : "opaq"} mod:${modulated ? cmd.x6 : "-"} "
      //     "xy(${p0_.x},${p0_.y})-(${p1_.x},${p1_.y})-(${p2_.x},${p2_.y}}) "
      //     "->(${p0_.x + drawingOffsetX},${p0_.y + drawingOffsetY})-(${p1_.x + drawingOffsetX},${p1_.y + drawingOffsetY})-(${p2_.x + drawingOffsetX},${p2_.y + drawingOffsetY}) "
      //     "c${[4, 8, 15, 16][clutMode]} page:${status.x4} "
      //     "uv(${p0_.u}, ${p0_.v})-(${p1_.u},${p1_.v})-(${p2_.u},${p2_.v})) "
      //     "->(${p0_.u + baseX},${p0_.v + baseY})-(${p1_.u + baseX},${p1_.v + baseY})-(${p2_.u + baseX},${p2_.v + baseY})) "
      //     "(+$textureOffsetX/${textureMaskX.x2},+$textureOffsetY/${textureMaskY.x2}) "
      //     "${!clutMode.bit1 ? "clut:${clut.x4} ${clut << 4 & 0x3f0},${clut >> 6 & 0x1ff} ${dumpClut(clut, status)} " : ""}");
    }

    final x1 = drawingX1 - drawingOffsetX;
    final y1 = drawingY1 - drawingOffsetY;
    final x2 = drawingX2 - drawingOffsetX;
    final y2 = drawingY2 - drawingOffsetY;

    for (final (p0, p1, p2) in polygons) {
      if (p0.y > y2 ||
          p2.y < y1 ||
          (p0.x < x1 && p1.x < x1 && p2.x < x1) ||
          (p0.x > x2 && p1.x > x2 && p2.x > x2) ||
          _tooLarge(p0, p1) ||
          _tooLarge(p1, p2) ||
          _tooLarge(p0, p2)) {
        continue;
      }

      for (int y = p0.y; y < p2.y; y++) {
        final p012 = y >= p1.y ? p1.mixY(p2, y) : p0.mixY(p1, y);
        final p02 = p0.mixY(p2, y);

        final (left, right) = p012.x > p02.x ? (p02, p012) : (p012, p02);
        final width = right.x - left.x;

        for (int x = left.x; x < right.x; x++) {
          final part = x - left.x;
          final u = (left.u * (width - part) + right.u * part) ~/ width;
          final v = (left.v * (width - part) + right.v * part) ~/ width;
          final texColor =
              getTextureColor2(u, v, baseX, baseY, clutBase, clutMode);
          if (texColor != 0) {
            final c16 = !modulated
                ? texColor
                : ditherAndModulate(x, y, texColor,
                    gouraud ? left.c.mix(right.c, part, width) : modulateColor);
            pset16(x, y, c16,
                blend: transparent && texColor.bit15,
                semiTransparent: semiTransparent);
          }
        }
      }
    }
    return true;
  }
}
