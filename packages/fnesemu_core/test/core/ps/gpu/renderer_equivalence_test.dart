import 'dart:math';
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ps/bus.dart';
import 'package:fnesemu_core/src/core/ps/gpu/gpu.dart';
import 'package:fnesemu_core/src/core/ps/gpu/point_color.dart';
import 'package:fnesemu_core/src/util/int.dart';
import 'package:test/test.dart';

/// the straightforward polygon renderer (Point/Color per pixel), as the
/// reference for the optimized one in gpu0_renderer.dart
extension _Reference on Gpu {
  void refPset16(int x, int y, int c16,
      {bool blend = false, int? semiTransparent}) {
    x += drawingOffsetX;
    y += drawingOffsetY;
    if ((x < drawingX1 || x > drawingX2 || y < drawingY1 || y > drawingY2)) {
      return;
    }
    final old = frameBuffer16[y * 1024 + x];
    if (status.bit12 && old.bit15) {
      return;
    }
    if (blend) {
      final r0 = old & 0x1f;
      final g0 = old.shr5 & 0x1f;
      final b0 = old.shr10 & 0x1f;
      final r1 = c16 & 0x1f;
      final g1 = c16.shr5 & 0x1f;
      final b1 = c16.shr10 & 0x1f;
      c16 = c16 & 0x8000 |
          switch (semiTransparent ?? status.shr5 & 0x03) {
            0 => (b0 + b1).shr1.shl10 | (g0 + g1).shr1.shl5 | (r0 + r1).shr1,
            1 => 31.min(b0 + b1).shl10 | 31.min(g0 + g1).shl5 | 31.min(r0 + r1),
            2 => 0.max(b0 - b1).shl10 | 0.max(g0 - g1).shl5 | 0.max(r0 - r1),
            _ => 31.min(b0 + b1.shr2).shl10 |
                31.min(g0 + g1.shr2).shl5 |
                31.min(r0 + r1.shr2),
          };
    }
    final forceBit15 = status.bit11 ? 0x8000 : 0;
    writeFrameBuffer16(x, y, c16 | forceBit15);
  }

  (Point, Point, Point) refSort(Point p0, Point p1, Point p2) {
    if (p1.y < p0.y) (p0, p1) = (p1, p0);
    if (p2.y < p1.y) (p1, p2) = (p2, p1);
    if (p1.y < p0.y) (p0, p1) = (p1, p0);
    return (p0, p1, p2);
  }

  static bool tooLarge(Point p0, Point p1) =>
      (p1.x - p0.x).abs() >= 1024 || (p1.y - p0.y).abs() >= 512;

  void refFlat(int cmd, int v0, int v1, int v2) {
    final c24 = Color.ofC24(cmd);
    final (p0, p1, p2) =
        refSort(Point.of(v0, 0, 0), Point.of(v1, 0, 0), Point.of(v2, 0, 0));
    final transparent = cmd.bit25;
    if (tooLarge(p0, p1) || tooLarge(p1, p2) || tooLarge(p0, p2)) return;
    final c15 = c24.c15;
    for (int y = p0.y; y < p2.y; y++) {
      final p012 = y >= p1.y ? p1.mixY(p2, y) : p0.mixY(p1, y);
      final p02 = p0.mixY(p2, y);
      final (left, right) = p012.x > p02.x ? (p02, p012) : (p012, p02);
      for (int x = left.x; x < right.x; x++) {
        refPset16(x, y, c15, blend: transparent);
      }
    }
  }

  void refGouraud(int cmd, int c0, int v0, int c1, int v1, int c2, int v2) {
    final (p0, p1, p2) =
        refSort(Point.of(v0, c0, 0), Point.of(v1, c1, 0), Point.of(v2, c2, 0));
    final transparent = cmd.bit25;
    if (tooLarge(p0, p1) || tooLarge(p1, p2) || tooLarge(p0, p2)) return;
    for (int y = p0.y; y < p2.y; y++) {
      final p012 = y >= p1.y ? p1.mixY(p2, y) : p0.mixY(p1, y);
      final p02 = p0.mixY(p2, y);
      final (left, right) = p012.x > p02.x ? (p02, p012) : (p012, p02);
      for (int x = left.x; x < right.x; x++) {
        final c = left.c.mix(right.c, x - left.x, right.x - left.x);
        refPset16(x, y, dither(x, y, c), blend: transparent);
      }
    }
  }

  void refTextured(List<int> c) {
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
    final clutBase = (clut.shr6 & 0x1ff) * 1024 + (clut & 0x3f).shl4;
    final p0_ = gouraud ? Point.of(c[1], c[0], c[2]) : Point.of(c[1], 0, c[2]);
    final p1_ = gouraud ? Point.of(c[4], c[3], c[5]) : Point.of(c[3], 0, c[4]);
    final p2_ = gouraud ? Point.of(c[7], c[6], c[8]) : Point.of(c[5], 0, c[6]);
    final polygons = [refSort(p0_, p1_, p2_)];
    if (rectangle) {
      final p3_ =
          gouraud ? Point.of(c[10], c[9], c[11]) : Point.of(c[7], 0, c[8]);
      polygons.add(refSort(p1_, p2_, p3_));
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
          tooLarge(p0, p1) ||
          tooLarge(p1, p2) ||
          tooLarge(p0, p2)) {
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
            refPset16(x, y, c16,
                blend: transparent && texColor.bit15,
                semiTransparent: semiTransparent);
          }
        }
      }
    }
  }
}

void main() {
  test('rectangle clipping preserves texture coordinates and drawing offsets',
      () {
    final full = Gpu(Bus());
    final clipped = Gpu(Bus());
    final initial = Uint16List(full.frameBuffer16.length);
    for (int y = 0; y < 256; y++) {
      for (int x = 0; x < 256; x++) {
        initial[y * 1024 + 512 + x] = 1 + (x + y * 256) % 0x7fff;
      }
    }

    for (final offset in [-20, 0, 20]) {
      for (final (x1, y1, x2, y2) in [
        (0, 0, 1023, 511),
        (45, 45, 50, 50),
        (48, 48, 48, 48),
        (20, 60, 25, 65),
        (60, 20, 65, 25),
        (0, 0, 10, 10),
        (60, 60, 50, 50),
      ]) {
        for (final g in [full, clipped]) {
          g.frameBuffer16.setAll(0, initial);
          g.status = 0x108; // Direct color texture at x=512.
          g.drawingX1 = 0;
          g.drawingY1 = 0;
          g.drawingX2 = 1023;
          g.drawingY2 = 511;
          g.drawingOffsetX = offset;
          g.drawingOffsetY = -offset;
        }
        clipped.drawingX1 = x1;
        clipped.drawingY1 = y1;
        clipped.drawingX2 = x2;
        clipped.drawingY2 = y2;
        for (final g in [full, clipped]) {
          for (final word in [
            0x65000000,
            40 | (40 << 16),
            3 | (5 << 8),
            32 | (32 << 16)
          ]) {
            g.writeGp0(word);
          }
        }
        expect(
            full.frameBuffer16[(40 - offset) * 1024 + 40 + offset], isNot(0));
        final expected = Uint16List.fromList(initial);
        for (int y = y1; y <= y2; y++) {
          for (int x = x1; x <= x2; x++) {
            expected[y * 1024 + x] = full.frameBuffer16[y * 1024 + x];
          }
        }
        expect(clipped.frameBuffer16, orderedEquals(expected),
            reason: 'offset=$offset area=($x1,$y1)-($x2,$y2)');
      }
    }
  });

  test('optimized polygon renderer matches the reference', () {
    final random = Random(1);
    final a = Gpu(Bus());
    final b = Gpu(Bus());

    int vertex(int range) {
      final x = random.nextInt(range) - range ~/ 4;
      final y = random.nextInt(range ~/ 2) - range ~/ 8;
      return x & 0x7ff | (y & 0x7ff).shl16;
    }

    for (int round = 0; round < 3000; round++) {
      if (round % 100 == 0) {
        for (int i = 0; i < a.frameBuffer16.length; i++) {
          a.frameBuffer16[i] = b.frameBuffer16[i] = random.nextInt(0x10000);
        }
      }
      for (final g in [a, b]) {
        g.status = 0;
      }
      final status = random.nextInt(0x2000);
      final x1 = random.nextInt(1024), x2 = random.nextInt(1024);
      final y1 = random.nextInt(512), y2 = random.nextInt(512);
      final ox = random.nextInt(200) - 100, oy = random.nextInt(200) - 100;
      final window = random.nextBool() ? 0 : random.nextInt(1 << 20);
      for (final g in [a, b]) {
        g.status = status;
        g.drawingX1 = min(x1, x2);
        g.drawingX2 = random.nextInt(20) == 0 ? min(x1, x2) : max(x1, x2);
        g.drawingY1 = min(y1, y2);
        g.drawingY2 = max(y1, y2);
        g.drawingOffsetX = ox;
        g.drawingOffsetY = oy;
        g.writeGp0(0xe2000000 | window);
      }
      b.drawingX2 = a.drawingX2;

      final range = random.nextBool() ? 64 : 1200;
      final cmd = random.nextInt(0x1000000) | random.nextInt(0x20).shl24;
      switch (random.nextInt(3)) {
        case 0:
          final v = [vertex(range), vertex(range), vertex(range)];
          a.refFlat(cmd, v[0], v[1], v[2]);
          b.renderFlatPolygon(cmd, v[0], v[1], v[2]);
        case 1:
          final v = [vertex(range), vertex(range), vertex(range)];
          final c = [cmd, random.nextInt(0x1000000), random.nextInt(0x1000000)];
          a.refGouraud(cmd, c[0], v[0], c[1], v[1], c[2], v[2]);
          b.renderGouraudPolygon(cmd, c[0], v[0], c[1], v[1], c[2], v[2]);
        default:
          final gouraud = cmd.bit28;
          final words = <int>[cmd];
          for (int i = 0; i < 4; i++) {
            if (gouraud && i > 0) words.add(random.nextInt(0x1000000));
            words.add(vertex(range));
            words.add(random.nextInt(0x10000) | random.nextInt(0x10000).shl16);
          }
          a.refTextured(words);
          b.renderTexturedGouraudPolygon4(words);
      }

      final a64 = a.frameBuffer.buffer.asUint64List();
      final b64 = b.frameBuffer.buffer.asUint64List();
      for (int j = 0; j < a64.length; j++) {
        if (a64[j] == b64[j]) continue;
        final i = j * 4;
        {
          fail("round $round: vram differs at $i "
              "${a.frameBuffer16[i].x4} != ${b.frameBuffer16[i].x4}");
        }
      }
    }
  });
}
