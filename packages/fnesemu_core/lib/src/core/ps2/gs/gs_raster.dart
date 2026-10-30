import 'dart:math' as math;
import 'dart:typed_data';

import '../state.dart';
import 'gs.dart';
import 'gs_memory.dart';

/// Draws primitives into the GS local memory.
///
/// Not implemented: antialiasing (AA1), dithering, mipmapping (the magnify
/// filter is used for every texture), the Z buffer alpha-test modes beyond
/// the four AFAIL cases, and the destination alpha test for 24-bit frames.
class GsRaster {
  final Gs gs;

  GsRaster(this.gs);

  // ---- state decoded at the start of a primitive ----
  late GsContext _ctx;
  int _fbp = 0, _fbw = 0, _fpsm = 0, _fbmsk = 0, _fba = 0;
  int _zbp = 0, _zpsm = 0, _zmax = 0;
  late GsLayout _frameLayout, _zLayout, _texLayout;
  int _framePages = 0, _zPages = 0, _texPages = 0;
  bool _zmsk = false;
  int _ofx = 0, _ofy = 0;
  int _sx0 = 0, _sx1 = 0, _sy0 = 0, _sy1 = 0;
  bool _ate = false, _date = false, _datm = false, _zte = true;
  int _atst = 0, _aref = 0, _afail = 0, _ztst = 0;
  bool _tme = false, _fge = false, _abe = false, _fst = false, _iip = false;
  int _blendA = 0, _blendB = 0, _blendC = 0, _blendD = 0, _fix = 0;

  // texture
  int _tbp = 0, _tbw = 0, _tpsm = 0, _tw = 0, _th = 0, _tcc = 0, _tfx = 0;
  int _clutPsm = 0, _clutOffset = 0;
  int _wms = 0, _wmt = 0, _minu = 0, _maxu = 0, _minv = 0, _maxv = 0;
  bool _linear = false;
  int _ta0 = 0, _ta1 = 0;
  bool _aem = false;

  // per-pixel scratch
  int _tr = 0, _tg = 0, _tb = 0, _ta = 0;
  int _dr = 0, _dg = 0, _db = 0, _da = 0;

  void _setup(int ctxIndex, int attrs) {
    _ctx = gs.contexts[ctxIndex];
    final frame = _ctx.frame;
    _fbp = (frame & 0x1ff) * 32;
    _fbw = (frame >> 16) & 0x3f;
    _fpsm = (frame >> 24) & 0x3f;
    _fbmsk = (frame >> 32) & 0xffffffff;
    _fba = _ctx.fba;
    final zbuf = _ctx.zbuf;
    _zbp = (zbuf & 0x1ff) * 32;
    _zpsm = 0x30 | ((zbuf >> 24) & 0xf);
    _zmsk = (zbuf >> 32) & 1 != 0;
    _zmax = switch (_zpsm) {
      GsPsm.z24 => 0xffffff,
      GsPsm.z16 || GsPsm.z16s => 0xffff,
      _ => 0xffffffff,
    };
    final mem = gs.mem;
    _frameLayout = mem.layout(_fpsm);
    _framePages = _frameLayout.pagesInRow(_fbw);
    _zLayout = mem.layout(_zpsm);
    // the Z buffer has the width of the frame buffer
    _zPages = _zLayout.pagesInRow(_fbw);
    _ofx = _ctx.xyoffset & 0xffff;
    _ofy = (_ctx.xyoffset >> 32) & 0xffff;
    final sc = _ctx.scissor;
    _sx0 = sc & 0x7ff;
    _sx1 = (sc >> 16) & 0x7ff;
    _sy0 = (sc >> 32) & 0x7ff;
    _sy1 = (sc >> 48) & 0x7ff;
    final test = _ctx.test;
    _ate = test & 1 != 0;
    _atst = (test >> 1) & 7;
    _aref = (test >> 4) & 0xff;
    _afail = (test >> 12) & 3;
    _date = (test >> 14) & 1 != 0;
    _datm = (test >> 15) & 1 != 0;
    _zte = (test >> 16) & 1 != 0;
    _ztst = (test >> 17) & 3;
    _tme = attrs & 0x10 != 0;
    _fge = attrs & 0x20 != 0;
    _abe = attrs & 0x40 != 0;
    _fst = attrs & 0x100 != 0;
    _iip = attrs & 0x08 != 0;
    final alpha = _ctx.alpha;
    _blendA = alpha & 3;
    _blendB = (alpha >> 2) & 3;
    _blendC = (alpha >> 4) & 3;
    _blendD = (alpha >> 6) & 3;
    _fix = (alpha >> 32) & 0xff;
    if (_tme) {
      final t0 = _ctx.tex0;
      _tbp = t0 & 0x3fff;
      _tbw = (t0 >> 14) & 0x3f;
      _tpsm = (t0 >> 20) & 0x3f;
      _tw = (t0 >> 26) & 15;
      _th = (t0 >> 30) & 15;
      _tcc = (t0 >> 34) & 1;
      _tfx = (t0 >> 35) & 3;
      _clutPsm = _clutFormat(t0);
      _clutOffset = _clutStart(t0, _clutPsm);
      _texLayout = mem.layout(_tpsm);
      _texPages = _texLayout.pagesInRow(_tbw);
      final c = _ctx.clamp;
      _wms = c & 3;
      _wmt = (c >> 2) & 3;
      _minu = (c >> 4) & 0x3ff;
      _maxu = (c >> 14) & 0x3ff;
      _minv = (c >> 24) & 0x3ff;
      _maxv = (c >> 34) & 0x3ff;
      _linear = (_ctx.tex1 >> 5) & 1 != 0;
      final texa = gs.texa;
      _ta0 = texa & 0xff;
      _aem = (texa >> 15) & 1 != 0;
      _ta1 = (texa >> 32) & 0xff;
    }
  }

  /// Draws one primitive. [type] is a Gs.prim* value, [attrs] the PRIM
  /// attribute bits in effect.
  void draw(Gs gs, int type, int attrs, GsVertex a, GsVertex b, GsVertex c) {
    _setup((attrs >> 9) & 1, attrs);
    switch (type) {
      case Gs.primPoint:
        _point(a, attrs);
      case Gs.primLine:
        _line(a, b);
      case Gs.primTriangle:
        _triangle(a, b, c);
      case Gs.primSprite:
        _sprite(a, b);
    }
  }

  // ---- primitives ----

  void _point(GsVertex v, int attrs) {
    final x = (v.x - _ofx) >> 4, y = (v.y - _ofy) >> 4;
    if (x < _sx0 || x > _sx1 || y < _sy0 || y > _sy1) return;
    _s = v.s;
    _t = v.t;
    _q = v.q;
    _uu = v.u / 16;
    _vv = v.v / 16;
    _pixel(x, y, v.z, v.r, v.g, v.b, v.a, v.f);
  }

  void _line(GsVertex a, GsVertex b) {
    final x0 = (a.x - _ofx) / 16, y0 = (a.y - _ofy) / 16;
    final x1 = (b.x - _ofx) / 16, y1 = (b.y - _ofy) / 16;
    final dx = x1 - x0, dy = y1 - y0;
    final steps = math.max(dx.abs(), dy.abs()).ceil();
    if (steps == 0) return;
    for (var i = 0; i < steps; i++) {
      final t = i / steps;
      final x = (x0 + dx * t).floor(), y = (y0 + dy * t).floor();
      if (x < _sx0 || x > _sx1 || y < _sy0 || y > _sy1) continue;
      _lerp(a, b, t);
      _pixel(x, y, (a.z + (b.z - a.z) * t).round(), _cr, _cg, _cb, _ca, _cf);
    }
  }

  int _cr = 0, _cg = 0, _cb = 0, _ca = 0, _cf = 0;

  void _lerp(GsVertex a, GsVertex b, double t) {
    if (_iip) {
      _cr = (a.r + (b.r - a.r) * t).round();
      _cg = (a.g + (b.g - a.g) * t).round();
      _cb = (a.b + (b.b - a.b) * t).round();
      _ca = (a.a + (b.a - a.a) * t).round();
    } else {
      _cr = b.r;
      _cg = b.g;
      _cb = b.b;
      _ca = b.a;
    }
    _cf = (a.f + (b.f - a.f) * t).round();
    _s = a.s + (b.s - a.s) * t;
    _t = a.t + (b.t - a.t) * t;
    _q = a.q + (b.q - a.q) * t;
    _uu = (a.u + (b.u - a.u) * t) / 16;
    _vv = (a.v + (b.v - a.v) * t) / 16;
  }

  void _sprite(GsVertex a, GsVertex b) {
    // a is the upper left corner and b the lower right one
    final x0 = a.x - _ofx, y0 = a.y - _ofy, x1 = b.x - _ofx, y1 = b.y - _ofy;
    final left = math.min(x0, x1), right = math.max(x0, x1);
    final top = math.min(y0, y1), bottom = math.max(y0, y1);
    final width = right - left, height = bottom - top;
    if (width == 0 || height == 0) return;
    var px0 = ((left - 8 + 15) >> 4);
    var py0 = ((top - 8 + 15) >> 4);
    if (px0 < _sx0) px0 = _sx0;
    if (py0 < _sy0) py0 = _sy0;
    for (var py = py0; py <= _sy1 && py * 16 + 8 < bottom; py++) {
      final ty = (py * 16 + 8 - top) / height;
      for (var px = px0; px <= _sx1 && px * 16 + 8 < right; px++) {
        final tx = (px * 16 + 8 - left) / width;
        _s = a.s + (b.s - a.s) * tx;
        _t = a.t + (b.t - a.t) * ty;
        _q = b.q;
        _uu = (a.u + (b.u - a.u) * tx) / 16;
        _vv = (a.v + (b.v - a.v) * ty) / 16;
        _pixel(px, py, b.z, b.r, b.g, b.b, b.a, b.f);
      }
    }
  }

  void _triangle(GsVertex a, GsVertex b, GsVertex c) {
    var ax = a.x - _ofx, ay = a.y - _ofy;
    var bx = b.x - _ofx, by = b.y - _ofy;
    var cx = c.x - _ofx, cy = c.y - _ofy;
    var area = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
    if (area == 0) return;
    GsVertex va = a, vb = b, vc = c;
    if (area < 0) {
      // make the orientation positive by swapping b and c
      (bx, cx) = (cx, bx);
      (by, cy) = (cy, by);
      vb = c;
      vc = b;
      area = -area;
    }
    final minX = math.max(math.min(ax, math.min(bx, cx)) >> 4, _sx0);
    final maxX = math.min((math.max(ax, math.max(bx, cx)) + 15) >> 4, _sx1);
    final minY = math.max(math.min(ay, math.min(by, cy)) >> 4, _sy0);
    final maxY = math.min((math.max(ay, math.max(by, cy)) + 15) >> 4, _sy1);
    // edge setup: E(p) = (x1 - x0) * (py - y0) - (y1 - y0) * (px - x0)
    final topLeftAb = _topLeft(bx - ax, by - ay);
    final topLeftBc = _topLeft(cx - bx, cy - by);
    final topLeftCa = _topLeft(ax - cx, ay - cy);
    final inv = 1.0 / area;
    // the edge values step by a multiple of 16 per pixel
    final dAbX = -(by - ay) * 16,
        dBcX = -(cy - by) * 16,
        dCaX = -(ay - cy) * 16;
    final needColor = _iip, needFog = _fge;
    final needStq = _tme && !_fst, needUv = _tme && _fst;
    for (var py = minY; py <= maxY; py++) {
      final qy = py * 16 + 8, qx = minX * 16 + 8;
      var eab = (bx - ax) * (qy - ay) - (by - ay) * (qx - ax);
      var ebc = (cx - bx) * (qy - by) - (cy - by) * (qx - bx);
      var eca = (ax - cx) * (qy - cy) - (ay - cy) * (qx - cx);
      for (var px = minX;
          px <= maxX;
          px++, eab += dAbX, ebc += dBcX, eca += dCaX) {
        if (eab < 0 || ebc < 0 || eca < 0) continue;
        if ((eab == 0 && !topLeftAb) ||
            (ebc == 0 && !topLeftBc) ||
            (eca == 0 && !topLeftCa)) {
          continue;
        }
        // the weights are not negative, so _round rounds as round() does
        final wa = ebc * inv, wb = eca * inv, wc = eab * inv;
        final z = _round(va.z * wa + vb.z * wb + vc.z * wc);
        if (needColor) {
          _cr = _round(va.r * wa + vb.r * wb + vc.r * wc);
          _cg = _round(va.g * wa + vb.g * wb + vc.g * wc);
          _cb = _round(va.b * wa + vb.b * wb + vc.b * wc);
          _ca = _round(va.a * wa + vb.a * wb + vc.a * wc);
        } else {
          _cr = c.r;
          _cg = c.g;
          _cb = c.b;
          _ca = c.a;
        }
        if (needFog) _cf = _round(va.f * wa + vb.f * wb + vc.f * wc);
        if (needStq) {
          _s = va.s * wa + vb.s * wb + vc.s * wc;
          _t = va.t * wa + vb.t * wb + vc.t * wc;
          _q = va.q * wa + vb.q * wb + vc.q * wc;
        } else if (needUv) {
          _uu = (va.u * wa + vb.u * wb + vc.u * wc) / 16;
          _vv = (va.v * wa + vb.v * wb + vc.v * wc) / 16;
        }
        _pixel(px, py, z, _cr, _cg, _cb, _ca, _cf);
      }
    }
  }

  static bool _topLeft(int dx, int dy) => (dy == 0 && dx > 0) || dy < 0;

  // ---- pixel pipeline ----

  double _s = 0, _t = 0, _q = 1, _uu = 0, _vv = 0;

  static int _clamp8(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

  void _pixel(int x, int y, int z, int r, int g, int b, int a, int f) {
    if (_tme) {
      _texture(r, g, b, a);
      r = _tr;
      g = _tg;
      b = _tb;
      a = _ta;
    }
    if (_fge) {
      final fc = gs.fogcol;
      r = (f * r + (255 - f) * (fc & 0xff)) >> 8;
      g = (f * g + (255 - f) * ((fc >> 8) & 0xff)) >> 8;
      b = (f * b + (255 - f) * ((fc >> 16) & 0xff)) >> 8;
    }
    var writeColor = true, writeZ = !_zmsk;
    if (_ate && !_alphaPasses(a)) {
      switch (_afail) {
        case 0:
          return;
        case 1:
          writeZ = false;
        case 2:
          writeColor = false;
        default:
          writeZ = false;
      }
    }
    final mem = gs.mem;
    final fi = _frameLayout.index(_fbp, _framePages, x, y);
    final fraw = mem.readAt(_fpsm, fi);
    if (_date) {
      final bit = switch (_fpsm) {
        GsPsm.ct32 => (fraw >> 31) & 1,
        GsPsm.ct16 || GsPsm.ct16s => (fraw >> 15) & 1,
        _ => 0,
      };
      if ((bit != 0) != _datm) return;
    }
    if (z < 0) z = 0;
    if (z > _zmax) z = _zmax;
    final zi = _zLayout.index(_zbp, _zPages, x, y);
    if (_zte) {
      final zold = mem.readAt(_zpsm, zi);
      final pass = switch (_ztst) {
        0 => false,
        1 => true,
        2 => z >= zold,
        _ => z > zold,
      };
      if (!pass) return;
    }
    if (writeZ) mem.writeAt(_zpsm, zi, z);
    if (!writeColor) return;
    if (_abe && (gs.pabe == 0 || a & 0x80 != 0)) {
      _decodeFrame(fraw);
      final coef = _blendC == 0 ? a : (_blendC == 1 ? _da : _fix);
      final clamp = gs.colclamp != 0;
      r = _blend(r, _dr, coef, clamp);
      g = _blend(g, _dg, coef, clamp);
      b = _blend(b, _db, coef, clamp);
    }
    _writeFrame(fi, fraw, r & 0xff, g & 0xff, b & 0xff, a & 0xff);
  }

  /// one channel of (A - B) * C >> 7 + D from source [cs] and destination
  /// [cd]
  int _blend(int cs, int cd, int coef, bool clamp) {
    final pa = _blendA == 0 ? cs : (_blendA == 1 ? cd : 0);
    final pb = _blendB == 0 ? cs : (_blendB == 1 ? cd : 0);
    final pd = _blendD == 0 ? cs : (_blendD == 1 ? cd : 0);
    final v = (((pa - pb) * coef) >> 7) + pd;
    return clamp ? _clamp8(v) : v & 0xff;
  }

  bool _alphaPasses(int a) => switch (_atst) {
        0 => false,
        1 => true,
        2 => a < _aref,
        3 => a <= _aref,
        4 => a == _aref,
        5 => a >= _aref,
        6 => a > _aref,
        _ => a != _aref,
      };

  void _decodeFrame(int raw) {
    switch (_fpsm) {
      case GsPsm.ct16 || GsPsm.ct16s:
        _dr = (raw & 31) << 3;
        _dg = ((raw >> 5) & 31) << 3;
        _db = ((raw >> 10) & 31) << 3;
        _da = (raw >> 15) & 1 != 0 ? 0x80 : 0;
      case GsPsm.ct24:
        _dr = raw & 0xff;
        _dg = (raw >> 8) & 0xff;
        _db = (raw >> 16) & 0xff;
        _da = 0x80;
      default:
        _dr = raw & 0xff;
        _dg = (raw >> 8) & 0xff;
        _db = (raw >> 16) & 0xff;
        _da = (raw >> 24) & 0xff;
    }
  }

  void _writeFrame(int fi, int old, int r, int g, int b, int a) {
    int packed;
    int mask;
    switch (_fpsm) {
      case GsPsm.ct16 || GsPsm.ct16s:
        packed =
            (r >> 3) | ((g >> 3) << 5) | ((b >> 3) << 10) | ((a >> 7) << 15);
        if (_fba != 0) packed |= 0x8000;
        mask = _fbmsk & 0xffff;
      case GsPsm.ct24:
        packed = r | (g << 8) | (b << 16);
        mask = _fbmsk & 0xffffff;
      default:
        packed = r | (g << 8) | (b << 16) | (a << 24);
        if (_fba != 0) packed |= 0x80000000;
        mask = _fbmsk;
    }
    gs.mem.writeAt(_fpsm, fi, (old & mask) | (packed & ~mask));
  }

  // ---- texturing ----

  void _texture(int r, int g, int b, int a) {
    final size = 1 << _tw, height = 1 << _th;
    double u, v;
    if (_fst) {
      u = _uu;
      v = _vv;
    } else {
      final q = _q == 0 ? 1.0 : _q;
      u = _finite(_s / q * size);
      v = _finite(_t / q * height);
    }
    int texel;
    if (_linear) {
      final u0 = (u - 0.5).floor(), v0 = (v - 0.5).floor();
      final fu = u - 0.5 - u0, fv = v - 0.5 - v0;
      final ua = _wrap(u0, _wms, size, _minu, _maxu);
      final ub = _wrap(u0 + 1, _wms, size, _minu, _maxu);
      final va = _wrap(v0, _wmt, height, _minv, _maxv);
      final vb = _wrap(v0 + 1, _wmt, height, _minv, _maxv);
      final c00 = _texel(ua, va), c10 = _texel(ub, va);
      final c01 = _texel(ua, vb), c11 = _texel(ub, vb);
      // equal texels mix to the same texel within the rounding
      texel = c00 == c10 && c00 == c01 && c00 == c11
          ? c00
          : _bilinear(c00, c10, c01, c11, fu, fv);
    } else {
      texel = _texel(_wrap(u.floor(), _wms, size, _minu, _maxu),
          _wrap(v.floor(), _wmt, height, _minv, _maxv));
    }
    final tr = texel & 0xff, tg = (texel >> 8) & 0xff;
    final tb = (texel >> 16) & 0xff, ta = (texel >> 24) & 0xff;
    switch (_tfx) {
      case 0:
        _tr = _clamp8((tr * r) >> 7);
        _tg = _clamp8((tg * g) >> 7);
        _tb = _clamp8((tb * b) >> 7);
        _ta = _tcc != 0 ? _clamp8((ta * a) >> 7) : a;
      case 1:
        _tr = tr;
        _tg = tg;
        _tb = tb;
        _ta = _tcc != 0 ? ta : a;
      case 2:
        _tr = _clamp8(((tr * r) >> 7) + a);
        _tg = _clamp8(((tg * g) >> 7) + a);
        _tb = _clamp8(((tb * b) >> 7) + a);
        _ta = _tcc != 0 ? _clamp8(ta + a) : a;
      default:
        _tr = _clamp8(((tr * r) >> 7) + a);
        _tg = _clamp8(((tg * g) >> 7) + a);
        _tb = _clamp8(((tb * b) >> 7) + a);
        _ta = _tcc != 0 ? ta : a;
    }
  }

  /// the bilinear mix of four texels in the RGBA8888 layout of [_texel]
  static int _bilinear(
      int c00, int c10, int c01, int c11, double fu, double fv) {
    final r =
        _round(_mix(c00 & 0xff, c10 & 0xff, c01 & 0xff, c11 & 0xff, fu, fv));
    final g = _round(_mix((c00 >> 8) & 0xff, (c10 >> 8) & 0xff,
        (c01 >> 8) & 0xff, (c11 >> 8) & 0xff, fu, fv));
    final b = _round(_mix((c00 >> 16) & 0xff, (c10 >> 16) & 0xff,
        (c01 >> 16) & 0xff, (c11 >> 16) & 0xff, fu, fv));
    final a = _round(_mix((c00 >> 24) & 0xff, (c10 >> 24) & 0xff,
        (c01 >> 24) & 0xff, (c11 >> 24) & 0xff, fu, fv));
    return r | g << 8 | b << 16 | a << 24;
  }

  /// [v] limited to the range of the texel coordinates; NaN gives 0. S, T
  /// and Q are floats that may hold anything, while the GS works on fixed
  /// point coordinates.
  static double _finite(double v) =>
      v.isNaN ? 0 : (v < -32768.0 ? -32768.0 : (v > 32768.0 ? 32768.0 : v));

  /// rounds a value that is not negative, as round() does
  static int _round(double v) => (v + 0.5).toInt();

  static double _mix(
          int c00, int c10, int c01, int c11, double fu, double fv) =>
      (c00 * (1 - fu) + c10 * fu) * (1 - fv) + (c01 * (1 - fu) + c11 * fu) * fv;

  static int _wrap(int c, int mode, int size, int minv, int maxv) {
    switch (mode) {
      case 0:
        return c & (size - 1);
      case 1:
        return c < 0 ? 0 : (c > size - 1 ? size - 1 : c);
      case 2:
        return c < minv ? minv : (c > maxv ? maxv : c);
      default:
        return (c & minv) | maxv;
    }
  }

  /// the texel at the wrapped coordinates (u, v) in RGBA8888
  int _texel(int u, int v) {
    final mem = gs.mem;
    final i = _texLayout.index(_tbp, _texPages, u, v);
    switch (_tpsm) {
      case GsPsm.ct32:
        return mem.word(i);
      case GsPsm.t8 || GsPsm.t8h:
        return _clut(mem.readAt(_tpsm, i));
      case GsPsm.t4 || GsPsm.t4hl || GsPsm.t4hh:
        return _clut(mem.readAt(_tpsm, i));
      default:
        return _color(_tpsm, mem.readAt(_tpsm, i));
    }
  }

  /// decodes a texel or CLUT entry of format [psm] into RGBA8888
  int _color(int psm, int raw) {
    switch (psm) {
      case GsPsm.ct32:
        return raw & 0xffffffff;
      case GsPsm.ct24:
        final rgb = raw & 0xffffff;
        return rgb | (_aem && rgb == 0 ? 0 : _ta0) << 24;
      default:
        final alpha =
            _aem && raw & 0x7fff == 0 ? 0 : (raw & 0x8000 != 0 ? _ta1 : _ta0);
        return (raw & 31) << 3 |
            ((raw >> 5) & 31) << 11 |
            ((raw >> 10) & 31) << 19 |
            alpha << 24;
    }
  }

  // ---- CLUT buffer ----

  // The CLUT buffer holds 256 entries of a 32-bit format or 512 entries of a
  // 16-bit format, as raw values.
  final _clutBuffer = Uint32List(512);
  int _cbp0 = 0, _cbp1 = 0;

  /// The CLUT buffer is the only state kept between primitives.
  void saveState(StateWriter w) {
    w.typed(_clutBuffer);
    w.ints([_cbp0, _cbp1]);
  }

  void loadState(StateReader s) {
    s.typed(_clutBuffer);
    final v = s.fields(2, 'gs clut');
    _cbp0 = v[0];
    _cbp1 = v[1];
  }

  static int _clutFormat(int tex0) => switch ((tex0 >> 51) & 15) {
        0 => GsPsm.ct32,
        1 => GsPsm.ct24,
        0xa => GsPsm.ct16s,
        _ => GsPsm.ct16,
      };

  static bool _isIndexed(int psm) =>
      psm == GsPsm.t8 ||
      psm == GsPsm.t8h ||
      psm == GsPsm.t4 ||
      psm == GsPsm.t4hl ||
      psm == GsPsm.t4hh;

  /// the first buffer entry of the texture: CSA selects a group of 16
  /// entries for the 4-bit formats and for the 16-bit CLUT formats
  static int _clutStart(int tex0, int clutPsm) {
    final csa = (tex0 >> 56) & 31;
    if (GsPsm.bits(clutPsm) == 16) return csa * 16;
    return GsPsm.pixelBits((tex0 >> 20) & 0x3f) == 4 ? (csa & 15) * 16 : 0;
  }

  /// Loads the CLUT buffer from local memory when CLD of a TEX0 or TEX2
  /// write asks for it. The load is done for the indexed formats only.
  void loadClut(int tex0) {
    final psm = (tex0 >> 20) & 0x3f;
    if (!_isIndexed(psm)) return;
    final cbp = (tex0 >> 37) & 0x3fff;
    switch ((tex0 >> 61) & 7) {
      case 1:
        break;
      case 2:
        _cbp0 = cbp;
      case 3:
        _cbp1 = cbp;
      case 4:
        if (cbp == _cbp0) return;
        _cbp0 = cbp;
      case 5:
        if (cbp == _cbp1) return;
        _cbp1 = cbp;
      default:
        return;
    }
    final cpsm = _clutFormat(tex0);
    final start = _clutStart(tex0, cpsm);
    final eight = GsPsm.pixelBits(psm) == 8;
    final count = eight ? 256 : 16;
    final mem = gs.mem;
    if ((tex0 >> 55) & 1 == 0) {
      // CSM1: the entries are pixels of a 16x16 image for the 8-bit formats
      // and of an 8x2 image for the 4-bit ones. In the 16x16 image, the
      // position of an entry swaps bits 3 and 4 of its index.
      for (var i = 0; i < count; i++) {
        final x = eight ? (i & 7) | (i & 0x10) >> 1 : i & 7;
        final y = eight ? (i & 0xe0) >> 4 | (i & 8) >> 3 : i >> 3;
        _clutBuffer[(start + i) & 511] = mem.read(cpsm, cbp, 1, x, y);
      }
    } else {
      // CSM2: the entries are pixels of a row of the CLUT buffer image
      final cbw = gs.texclut & 0x3f;
      final cou = ((gs.texclut >> 6) & 0x3f) * 16;
      final cov = (gs.texclut >> 12) & 0x3ff;
      for (var i = 0; i < count; i++) {
        _clutBuffer[(start + i) & 511] = mem.read(cpsm, cbp, cbw, cou + i, cov);
      }
    }
  }

  int _clut(int index) =>
      _color(_clutPsm, _clutBuffer[(_clutOffset + index) & 511]);
}
