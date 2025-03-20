class Color {
  final int r;
  final int g;
  final int b;

  Color(this.r, this.g, this.b);

  Color.ofC24(int c24)
      : b = c24 >> 16 & 0xff,
        g = c24 >> 8 & 0xff,
        r = c24 & 0xff;

  int get c24 => b << 16 | g << 8 | r;
  int get c15 => b << 7 & 0x7c00 | g << 2 & 0x3e0 | r >> 3 & 0x1f;

  Color mix(Color c, int part, int total) {
    if (total == 0) {
      return this;
    }
    final r = (this.r * (total - part) + c.r * part) ~/ total;
    final g = (this.g * (total - part) + c.g * part) ~/ total;
    final b = (this.b * (total - part) + c.b * part) ~/ total;
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
      : this(v & xMask, v >> 16 & yMask, Color.ofC24(c), t & 0xff,
            t >> 8 & 0xff);

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

  Point mixY(Point p, int y) {
    final part = y - this.y;
    final total = p.y - this.y;
    return mix(p, part, total);
  }
}
