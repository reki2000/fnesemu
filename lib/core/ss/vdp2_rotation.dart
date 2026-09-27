part of 'vdp2.dart';

// rotation parameter set read from the parameter table in VRAM
class _RotParam {
  double xst = 0, yst = 0, zst = 0;
  double dxst = 0, dyst = 0;
  double dx = 0, dy = 0;
  double a = 0, b = 0, c = 0, d = 0, e = 0, f = 0;
  double px = 0, py = 0, pz = 0;
  double cx = 0, cy = 0, cz = 0;
  double mx = 0, my = 0;
  double kx = 0, ky = 0;
  double kast = 0, dkast = 0, dkax = 0;

  // coefficient table settings
  bool coefEnabled = false;
  bool coefWord = false; // 1 word (16 bit) coefficient
  int coefMode = 0;
  int coefOffset = 0;

  // per line values
  double xsp = 0, ysp = 0, xp = 0, yp = 0, dX = 0, dY = 0, ka = 0;

  final cfg = _MapCfg();
  int overMode = 0;
}

extension on Vdp2 {
  static double _fx(int raw, int bits) {
    final m = (1 << bits) - 1;
    final v = raw & m;
    final s = (v & (1 << (bits - 1))) != 0 ? v - (1 << bits) : v;
    return s / 65536.0;
  }

  static int _sx(int raw, int bits) {
    final m = (1 << bits) - 1;
    final v = raw & m;
    return (v & (1 << (bits - 1))) != 0 ? v - (1 << bits) : v;
  }

  void _readRotParam(_RotParam r, int addr) {
    int l(int off) => vramData.getUint32((addr + off) & 0x7fffc);
    int w(int off) => vramData.getUint16((addr + off) & 0x7fffe);

    r.xst = _fx(l(0x00) & ~0x3f, 29);
    r.yst = _fx(l(0x04) & ~0x3f, 29);
    r.zst = _fx(l(0x08) & ~0x3f, 29);
    r.dxst = _fx(l(0x0c) & ~0x3f, 19);
    r.dyst = _fx(l(0x10) & ~0x3f, 19);
    r.dx = _fx(l(0x14) & ~0x3f, 19);
    r.dy = _fx(l(0x18) & ~0x3f, 19);
    r.a = _fx(l(0x1c) & ~0x3f, 20);
    r.b = _fx(l(0x20) & ~0x3f, 20);
    r.c = _fx(l(0x24) & ~0x3f, 20);
    r.d = _fx(l(0x28) & ~0x3f, 20);
    r.e = _fx(l(0x2c) & ~0x3f, 20);
    r.f = _fx(l(0x30) & ~0x3f, 20);
    r.px = _sx(w(0x34), 14).toDouble();
    r.py = _sx(w(0x36), 14).toDouble();
    r.pz = _sx(w(0x38), 14).toDouble();
    r.cx = _sx(w(0x3c), 14).toDouble();
    r.cy = _sx(w(0x3e), 14).toDouble();
    r.cz = _sx(w(0x40), 14).toDouble();
    r.mx = _fx(l(0x44) & ~0x3f, 30);
    r.my = _fx(l(0x48) & ~0x3f, 30);
    r.kx = _fx(l(0x4c), 24);
    r.ky = _fx(l(0x50), 24);
    r.kast = (l(0x54) & ~0x3f) / 65536.0;
    r.dkast = _fx(l(0x58) & ~0x3f, 26);
    r.dkax = _fx(l(0x5c) & ~0x3f, 26);
  }

  void _setupRotCfg(_RotParam r, int paramNo) {
    final cfg = r.cfg;
    final chctlb = reg(0x2a);

    cfg.colorMode = (chctlb >> 12) & 7;
    cfg.bitmap = chctlb.bit9;
    cfg.bitmapW = 512;
    cfg.bitmapH = chctlb.bit10 ? 512 : 256;
    cfg.char16 = chctlb.bit8;
    cfg.bitmapPalette = reg(0x2e) & 7;

    cfg.pncn = reg(0x38);
    cfg.pnSize = cfg.pncn.bit15 ? 2 : 4;

    final plsz = reg(0x3a) >> (paramNo == 0 ? 8 : 12);
    cfg.planeW = plsz & 3 == 0 ? 1 : 2;
    cfg.planeH = plsz & 3 == 3 ? 2 : 1;
    cfg.mapW = 4;
    r.overMode = (plsz >> 2) & 3;

    final mapOffset = (reg(0x3e) >> (paramNo * 4)) & 7;
    final mapRegs = paramNo == 0 ? 0x50 : 0x60;
    for (int i = 0; i < 8; i++) {
      final v = reg(mapRegs + i * 2);
      cfg.planeAddr[i * 2] = cfg.planeAddrOf(mapOffset << 6 | v & 0x3f);
      cfg.planeAddr[i * 2 + 1] =
          cfg.planeAddrOf(mapOffset << 6 | (v >> 8) & 0x3f);
    }

    cfg.bitmapAddr = mapOffset * 0x20000;
    cfg.craOffset = (reg(0xe6) & 7) << 8;
    cfg.transparentEnabled = !reg(0x20).bit12;
    cfg.priority = reg(0xfc) & 7;
    cfg.ccEnabled = reg(0xec).bit4;
    cfg.sfprMode = (reg(0xea) >> 8) & 3;

    final ktctl = reg(0xb4) >> (paramNo * 8);
    r.coefEnabled = ktctl.bit0;
    r.coefWord = ktctl.bit1;
    r.coefMode = (ktctl >> 2) & 3;
    r.coefOffset = ((reg(0xb6) >> (paramNo * 8)) & 7) << 16;
  }

  void _setupRotLine(_RotParam r, int y) {
    final xs = r.xst + r.dxst * y - r.px;
    final ys = r.yst + r.dyst * y - r.py;
    final zs = r.zst - r.pz;

    r.xsp = r.a * xs + r.b * ys + r.c * zs;
    r.ysp = r.d * xs + r.e * ys + r.f * zs;
    r.xp = r.a * (r.px - r.cx) +
        r.b * (r.py - r.cy) +
        r.c * (r.pz - r.cz) +
        r.cx +
        r.mx;
    r.yp = r.d * (r.px - r.cx) +
        r.e * (r.py - r.cy) +
        r.f * (r.pz - r.cz) +
        r.cy +
        r.my;
    r.dX = r.a * r.dx + r.b * r.dy;
    r.dY = r.d * r.dx + r.e * r.dy;
    r.ka = r.kast + r.dkast * y;
  }

  static const _transparentCoef = 0x7fffffff;

  // returns the coefficient value as 16.16 fixed, or _transparentCoef
  int _readCoef(_RotParam r, double ka) {
    final index = r.coefOffset + ka.floor();
    if (r.coefWord) {
      final d = vramData.getUint16((index * 2) & 0x7fffe);
      if (d.bit15) return _transparentCoef;
      return _sx(d, 15) << 6; // 4.10 -> 16.16
    }
    final d = vramData.getUint32((index * 4) & 0x7fffc);
    if (d.bit31) return _transparentCoef;
    return _sx(d, 24); // 8.16
  }

  /// returns packed pixel for screen x, or -1 when transparent by coefficient
  int _rotDot(_RotParam r, int x) {
    double kx = r.kx, ky = r.ky, xp = r.xp;

    if (r.coefEnabled) {
      final coef = _readCoef(r, r.ka + r.dkax * x);
      if (coef == _transparentCoef) {
        return -1;
      }
      final k = coef / 65536.0;
      switch (r.coefMode) {
        case 0:
          kx = k;
          ky = k;
          break;
        case 1:
          kx = k;
          break;
        case 2:
          ky = k;
          break;
        default:
          xp = k * 1024.0; // viewpoint Xp (14.10)
          break;
      }
    }

    final sx = (kx * (r.xsp + r.dX * x) + xp).floor();
    final sy = (ky * (r.ysp + r.dY * x) + r.yp).floor();
    final cfg = r.cfg;

    if (cfg.bitmap) {
      if (r.overMode >= 2 &&
          (sx < 0 || sy < 0 || sx >= cfg.bitmapW || sy >= cfg.bitmapH)) {
        return 0;
      }
      return _bitmapDot(cfg, sx, sy);
    }

    if (r.overMode == 2 &&
        (sx < 0 || sy < 0 || sx >= cfg.mapDotsW || sy >= cfg.mapDotsH)) {
      return 0;
    }
    if (r.overMode == 3 && (sx < 0 || sy < 0 || sx >= 512 || sy >= 512)) {
      return 0;
    }

    return _cellDot(cfg, sx, sy);
  }

  void _renderRbg0(int y, int w, Int32List buf) {
    final tableAddr = ((reg(0xbc) & 7) << 16 | reg(0xbe) & 0xfffe) << 1;
    final mode = reg(0xb0) & 3;

    final pa = _rotA;
    final pb = _rotB;

    _readRotParam(pa, tableAddr);
    _setupRotCfg(pa, 0);
    _setupRotLine(pa, y);

    final useB = mode == 1 || mode == 2;
    if (useB) {
      _readRotParam(pb, tableAddr + 0x80);
      _setupRotCfg(pb, 1);
      _setupRotLine(pb, y);
    }

    if (pa.cfg.priority == 0) {
      return;
    }

    _lastCellKey = -1;
    for (int x = 0; x < w; x++) {
      int p;
      if (mode == 1) {
        p = _rotDot(pb, x);
      } else {
        p = _rotDot(pa, x);
        if (p < 0 && mode == 2) {
          _lastCellKey = -1;
          p = _rotDot(pb, x);
          _lastCellKey = -1;
        }
      }
      buf[x] = p < 0 ? 0 : p;
    }
  }
}
