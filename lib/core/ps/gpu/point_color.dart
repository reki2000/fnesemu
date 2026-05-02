import 'package:fnesemu/util/int.dart';

class Color {
  final int r;
  final int g;
  final int b;

  @pragma('vm:prefer-inline')
  static int c5ToC8(int v) => (v << 3) | (v >> 2);

  Color(this.r, this.g, this.b);

  Color.ofC24(int c)
      : b = (c >> 16) & 0xff,
        g = (c >> 8) & 0xff,
        r = c & 0xff;

  Color.ofC15(int c)
      : b = c5ToC8((c >> 10) & 0x1f),
        g = c5ToC8((c >> 5) & 0x1f),
        r = c5ToC8(c & 0x1f);

  @pragma('vm:prefer-inline')
  int get c24 => b << 16 | g << 8 | r;
  @pragma('vm:prefer-inline')
  int get c15 => b << 7 & 0x7c00 | g << 2 & 0x3e0 | r >> 3 & 0x1f;

  @pragma('vm:prefer-inline')
  Color mix(Color c, int part, int total) {
    if (total == 0) {
      return this;
    }
    final r = (this.r * (total - part) + c.r * part) ~/ total;
    final g = (this.g * (total - part) + c.g * part) ~/ total;
    final b = (this.b * (total - part) + c.b * part) ~/ total;
    return Color(r, g, b);
  }

  @pragma('vm:prefer-inline')
  static int modulate(int c16, Color m24) {
    final r5 = c16 >> 10 & 0x1f;
    final g5 = c16 >> 5 & 0x1f;
    final b5 = c16 & 0x1f;
    final r = ((r5 << 5) + r5) * m24.r >> 12;
    final g = ((g5 << 5) + g5) * m24.g >> 12;
    final b = ((b5 << 5) + b5) * m24.b >> 12;
    final r2 = r > 31 ? 31 : r;
    final g2 = g > 31 ? 31 : g;
    final b2 = b > 31 ? 31 : b;
    return b2.shl10 | g2.shl5 | r2 | c16 & 0x8000;
  }
}

class Point {
  static const xMask = 0x3ff;
  static const yMask = 0x1ff;

  final int x;
  final int y;
  final int u;
  final int v;
  final Color c;

  Point(this.x, this.y, this.c, this.u, this.v);

  Point.of(int v, int c, int t)
      : this(v.rel11, (v >> 16).rel11, Color.ofC24(c), t & 0xff, t >> 8 & 0xff);

  @pragma('vm:prefer-inline')
  Point mix(Point p, int part, int total) {
    if (total == 0) {
      return this;
    }
    final x = (this.x * (total - part) + p.x * part) ~/ total;
    final y = (this.y * (total - part) + p.y * part) ~/ total;
    final u = (this.u * (total - part) + p.u * part) ~/ total;
    final v = (this.v * (total - part) + p.v * part) ~/ total;
    final c = this.c.mix(p.c, part, total);
    return Point(x, y, c, u, v);
  }

  @pragma('vm:prefer-inline')
  int abs(int v) => v < 0 ? -v : v;

  @pragma('vm:prefer-inline')
  Point mixY(Point p, int y) {
    final part = abs(y - this.y);
    final total = abs(p.y - this.y);
    return mix(p, part, total);
  }

  @pragma('vm:prefer-inline')
  Point mixX(Point p, int x) {
    final part = abs(x - this.x);
    final total = abs(p.x - this.x);
    return mix(p, part, total);
  }
}
