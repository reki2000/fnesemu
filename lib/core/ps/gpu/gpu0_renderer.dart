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
    final c24 = Color.ofC24(cmd);
    final (p0, p1, p2) = sortVertice(v0, v1, v2, 0, 0, 0, 0, 0, 0);
    final transparent = cmd.bit25;

    // debugLog(
    //     'GPU0: renderFlat (${p0.x},${p0.y}), (${p1.x},${p1.y}), (${p2.x},${p2.y})');

    for (int y = p0.y; y < p2.y; y++) {
      final p012 = y >= p1.y ? p1.mixY(p2, y) : p0.mixY(p1, y);
      final p02 = p0.mixY(p2, y);

      final (left, right) = p012.x > p02.x ? (p02, p012) : (p012, p02);
      for (int x = left.x; x < right.x; x++) {
        final c15 = dither(x, y, c24);
        pset16(x, y, c15 | (transparent ? 0x8000 : 0));
      }
    }

    return true;
  }

  bool renderGouraudPolygon(
      int cmd, int c0, int v0, int c1, int v1, int c2, int v2) {
    final (p0, p1, p2) = sortVertice(v0, v1, v2, c0, c1, c2, 0, 0, 0);
    final transparent = cmd.bit25;

    // debugLog(
    //     'gp0: drawPolygon: ${dumpCmd()} (${p0.x},${p0.y}:${p0.c.c24.hex32}), (${p1.x},${p1.y}:${p1.c.c24.hex32}), (${p2.x},${p2.y}:${p2.c.c24.hex32}) '
    //     'offset:$drawingOffsetX,$drawingOffsetY area:$drawingX1,$drawingY1-$drawingX2,$drawingY2 ');

    for (int y = p0.y; y < p2.y; y++) {
      final p012 = y >= p1.y ? p1.mixY(p2, y) : p0.mixY(p1, y);
      final p02 = p0.mixY(p2, y);

      final (left, right) = p012.x > p02.x ? (p02, p012) : (p012, p02);
      for (int x = left.x; x < right.x; x++) {
        final c = left.c.mix(right.c, x - left.x, right.x - left.x);
        final c15 = dither(x, y, c);
        pset16(x, y, c15 | (transparent ? 0x8000 : 0));
      }
    }

    return true;
  }

  bool renderTexturedGouraudPolygon4(List<int> c) {
    final cmd = c[0];
    final modulated = !cmd.bit24;
    final transparentMask = cmd.bit25 ? 0xffff : 0x7fff;
    final gouraud = cmd.bit28;
    final rectangle = cmd.bit27;
    final modulateColor = Color.ofC24(cmd);

    final clut = c[2] >> 16;
    final page = c[gouraud ? 5 : 4] >> 16;

    final semiTransparent = page.shr5 & 0x03;

    final baseX = page << 6 & 0x3c0;
    final baseY = page << 4 & 0x100;
    final clutMode = page >> 7 & 3;
    final clutBase = (clut >> 6 & yMask) * 1024 + ((clut & 0x3f) << 4);

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
      //     "gp0: vram(0,0): ${readFrameBuffer16(0, 100).hex16} ${readFrameBuffer16(320, 100).hex16} forceBit15:${status.bit11} writeMask:${status.bit12}");
      // debugLog("gp0: drawPolygonTex4: $debugCmdIndexInFrame ${dumpCmd()} "
      //     "${cmd.bit25 ? "semi:$semiTransparent" : "opaq"} mod:${modulated ? cmd.hex24 : "-"} "
      //     "xy(${p0_.x},${p0_.y})-(${p1_.x},${p1_.y})-(${p2_.x},${p2_.y})-(${p3_.x},${p3_.y}) "
      //     "->(${p0_.x + drawingOffsetX},${p0_.y + drawingOffsetY})-(${p1_.x + drawingOffsetX},${p1_.y + drawingOffsetY})-(${p2_.x + drawingOffsetX},${p2_.y + drawingOffsetY})-(${p3_.x + drawingOffsetX},${p3_.y + drawingOffsetY}) "
      //     "c${[4, 8, 15, 16][clutMode]} page:${status.hex16} "
      //     "uv(${p0_.u}, ${p0_.v})-(${p1_.u},${p1_.v})-(${p2_.u},${p2_.v})-(${p3_.u},${p3_.v}) "
      //     "->(${p0_.u + baseX},${p0_.v + baseY})-(${p1_.u + baseX},${p1_.v + baseY})-(${p2_.u + baseX},${p2_.v + baseY})-(${p3_.u + baseX},${p3_.v + baseY}) "
      //     "(+$textureOffsetX/${textureMaskX.hex8},+$textureOffsetY/${textureMaskY.hex8}) "
      //     "${!clutMode.bit1 ? "clut:${clut.hex16} ${clut << 4 & 0x3f0},${clut >> 6 & 0x1ff} ${dumpClut(clut, status)} " : ""}");
    } else {
      // debugLog("gp0: drawPolygonTex: ${dumpCmd()} "
      //     "${cmd.bit25 ? "semi:$semiTransparent" : "opaq"} mod:${modulated ? cmd.hex24 : "-"} "
      //     "xy(${p0_.x},${p0_.y})-(${p1_.x},${p1_.y})-(${p2_.x},${p2_.y}}) "
      //     "->(${p0_.x + drawingOffsetX},${p0_.y + drawingOffsetY})-(${p1_.x + drawingOffsetX},${p1_.y + drawingOffsetY})-(${p2_.x + drawingOffsetX},${p2_.y + drawingOffsetY}) "
      //     "c${[4, 8, 15, 16][clutMode]} page:${status.hex16} "
      //     "uv(${p0_.u}, ${p0_.v})-(${p1_.u},${p1_.v})-(${p2_.u},${p2_.v})) "
      //     "->(${p0_.u + baseX},${p0_.v + baseY})-(${p1_.u + baseX},${p1_.v + baseY})-(${p2_.u + baseX},${p2_.v + baseY})) "
      //     "(+$textureOffsetX/${textureMaskX.hex8},+$textureOffsetY/${textureMaskY.hex8}) "
      //     "${!clutMode.bit1 ? "clut:${clut.hex16} ${clut << 4 & 0x3f0},${clut >> 6 & 0x1ff} ${dumpClut(clut, status)} " : ""}");
    }

    final x1 = drawingX1 - drawingOffsetX;
    final y1 = drawingY1 - drawingOffsetY;
    final x2 = drawingX2 - drawingOffsetX;
    final y2 = drawingY2 - drawingOffsetY;

    for (final (p0, p1, p2) in polygons) {
      if (p0.y > y2 ||
          p2.y < y1 ||
          (p0.x < x1 && p1.x < x1 && p2.x < x1) ||
          (p0.x > x2 && p1.x > x2 && p2.x > x2)) {
        return true;
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
                : ditherAndModulate(0, 0, texColor,
                    gouraud ? left.c.mix(right.c, part, width) : modulateColor);
            pset16(x, y, c16 & transparentMask,
                semiTransparent: semiTransparent);
          }
        }
      }
    }
    return true;
  }
}
