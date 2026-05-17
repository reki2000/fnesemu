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
    final totalHalf = total ~/ 2;
    final totalMinusPart = total - part;
    final r = (this.r * totalMinusPart + c.r * part + totalHalf) ~/ total;
    final g = (this.g * totalMinusPart + c.g * part + totalHalf) ~/ total;
    final b = (this.b * totalMinusPart + c.b * part + totalHalf) ~/ total;
    return Color(r, g, b);
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
    final totalHalf = total ~/ 2;
    final totalMinusPart = total - part;
    final x = (this.x * totalMinusPart + p.x * part + totalHalf) ~/ total;
    final y = (this.y * totalMinusPart + p.y * part + totalHalf) ~/ total;
    final u = (this.u * totalMinusPart + p.u * part + totalHalf) ~/ total;
    final v = (this.v * totalMinusPart + p.v * part + totalHalf) ~/ total;
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
