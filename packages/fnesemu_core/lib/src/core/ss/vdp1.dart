import 'dart:typed_data';

import '../../state.dart';
import '../../util/int.dart';
import '../../video_debug.dart';

part 'vdp1_debug.dart';

/// VDP1: sprite / polygon renderer drawing into double-buffered frame buffers
class Vdp1 {
  final vram = Uint8List(0x80000);
  late final vramData = ByteData.sublistView(vram);

  static const fbWidth = 512;
  static const fbHeight = 256;

  final _fb = [Uint16List(fbWidth * fbHeight), Uint16List(fbWidth * fbHeight)];
  int _drawIndex = 0;

  /// TVMR bit 0: the frame buffer holds 8-bit pixels, 1024 x 256, two
  /// pixels to a word with the even pixel in the upper byte
  bool get eightBit => tvmr.bit0;

  Uint16List get displayFb => _fb[_drawIndex ^ 1];
  Uint16List get drawFb => _fb[_drawIndex];

  void Function() onDrawEnd = () {};

  // registers
  int tvmr = 0;
  int fbcr = 0;
  int ptmr = 0;
  int ewdr = 0;
  int ewlr = 0;
  int ewrr = 0;
  int edsr = 0;
  int lopr = 0;
  int copr = 0;

  bool _manualChange = false;
  bool _manualErase = false;

  // the manual erase of the field being displayed, done when the field ends
  bool _eraseDisplay = false;

  // pending draw end notification in SH-2 clocks
  int _drawEndWait = -1;

  // drawing states
  int _localX = 0, _localY = 0;
  int _sysClipX = 0, _sysClipY = 0;
  int _userX1 = 0, _userY1 = 0, _userX2 = 0, _userY2 = 0;

  int _pixels = 0;

  List<int> get _scalars => [
        tvmr,
        fbcr,
        ptmr,
        ewdr,
        ewlr,
        ewrr,
        edsr,
        lopr,
        copr,
        _drawIndex,
        _drawEndWait,
        _localX,
        _localY,
        _sysClipX,
        _sysClipY,
        _userX1,
        _userY1,
        _userX2,
        _userY2,
        _pixels,
        _pmod,
        _colr,
        _srca,
        _texW,
        _texH,
        _dir,
        _endCodes,
        _gr,
        _gg,
        _gb
      ];

  static Uint8List _bytes(TypedData d) =>
      d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes);

  /// Saves VRAM, both frame buffers, registers and drawing latches.
  void saveState(StateWriter w) {
    w.section('vdp1');
    w.bytes(vram);
    for (final fb in _fb) {
      w.bytes(_bytes(fb));
    }
    w.ints(_scalars);
    w.ints(_grd);
    w.boolean(_manualChange);
    w.boolean(_manualErase);
    w.boolean(_eraseDisplay);
  }

  void loadState(StateReader s) {
    s.section('vdp1');
    s.bytesInto(vram);
    for (final fb in _fb) {
      s.bytesInto(_bytes(fb));
    }
    final v = s.ints();
    if (v.length != _scalars.length) {
      throw const StateMismatch('vdp1 state layout');
    }
    var i = 0;
    tvmr = v[i++];
    fbcr = v[i++];
    ptmr = v[i++];
    ewdr = v[i++];
    ewlr = v[i++];
    ewrr = v[i++];
    edsr = v[i++];
    lopr = v[i++];
    copr = v[i++];
    _drawIndex = v[i++];
    _drawEndWait = v[i++];
    _localX = v[i++];
    _localY = v[i++];
    _sysClipX = v[i++];
    _sysClipY = v[i++];
    _userX1 = v[i++];
    _userY1 = v[i++];
    _userX2 = v[i++];
    _userY2 = v[i++];
    _pixels = v[i++];
    _pmod = v[i++];
    _colr = v[i++];
    _srca = v[i++];
    _texW = v[i++];
    _texH = v[i++];
    _dir = v[i++];
    _endCodes = v[i++];
    _gr = v[i++];
    _gg = v[i++];
    _gb = v[i++];
    s.intsInto(_grd);
    _manualChange = s.boolean();
    _manualErase = s.boolean();
    _eraseDisplay = s.boolean();
  }

  void reset() {
    tvmr = 0;
    fbcr = 0;
    ptmr = 0;
    ewdr = 0;
    ewlr = 0;
    ewrr = 0;
    edsr = 0;
    lopr = 0;
    copr = 0;
    _manualChange = false;
    _manualErase = false;
    _eraseDisplay = false;
    _drawEndWait = -1;
    for (final fb in _fb) {
      fb.fillRange(0, fb.length, 0);
    }
  }

  // ---- registers ----

  int readReg(int addr) {
    return switch (addr & 0x1e) {
      0x10 => edsr,
      0x12 => lopr,
      0x14 => copr,
      0x16 => 0x1000 |
          ptmr.mask2.shl8 |
          (fbcr & 0x1c).shl3 |
          (fbcr & 2).shl3 |
          tvmr.mask4,
      _ => 0,
    };
  }

  void writeReg(int addr, int data) {
    switch (addr & 0x1e) {
      case 0x00:
        tvmr = data.mask4;
        break;
      case 0x02:
        fbcr = data.mask5;
        if (fbcr.bit1) {
          if (fbcr.bit0) {
            _manualChange = true;
          } else {
            _manualErase = true;
          }
        }
        break;
      case 0x04:
        ptmr = data.mask2;
        if (ptmr == 1) {
          _draw();
        }
        break;
      case 0x06:
        ewdr = data;
        break;
      case 0x08:
        ewlr = data;
        break;
      case 0x0a:
        ewrr = data;
        break;
      case 0x0c:
        // ENDR: force end of drawing
        break;
    }
  }

  // ---- frame buffer access from CPU ----

  int readFb16(int addr) => drawFb[addr.shr1 & 0x1ffff];

  void writeFb16(int addr, int data, int mask) {
    final i = addr.shr1 & 0x1ffff;
    drawFb[i] = drawFb[i] & ~mask | data & mask;
  }

  void writeFb8(int addr, int data) {
    final i = addr.shr1 & 0x1ffff;
    drawFb[i] =
        addr.bit0 ? drawFb[i] & 0xff00 | data : drawFb[i].mask8 | data.shl8;
  }

  // ---- frame change ----

  /// called at the start of vertical blank
  void onVBlankIn() {
    // the erase follows the scan of the field it was requested for, so that field
    // still shows the picture and the buffer is clear when the frame changes
    if (_eraseDisplay) {
      _erase(displayFb);
      _eraseDisplay = false;
    }
    if (_manualErase) {
      _eraseDisplay = true;
      _manualErase = false;
    }

    final change = !fbcr.bit1 || _manualChange;
    _manualChange = false;

    if (!change) {
      return;
    }

    _drawIndex ^= 1;

    if (!fbcr.bit1) {
      _erase(drawFb);
    }

    // BEF <- CEF
    edsr = edsr.bit1 ? 1 : 0;

    if (ptmr == 2) {
      _draw();
    }
  }

  void exec(int clocks) {
    if (_drawEndWait < 0) {
      return;
    }
    _drawEndWait -= clocks;
    if (_drawEndWait < 0) {
      onDrawEnd();
    }
  }

  void _erase(Uint16List fb) {
    final x1 = ewlr.shr9.mask6 * 8;
    final y1 = ewlr.mask9;
    final x3 = ewrr.shr9.mask7 * 8;
    final y3 = ewrr.mask9;

    for (int y = y1; y <= y3 && y < fbHeight; y++) {
      final base = y * fbWidth;
      final xe = x3 < fbWidth ? x3 : fbWidth;
      if (x1 < xe) {
        fb.fillRange(base + x1, base + xe, ewdr);
      }
    }
  }

  // ---- command processing ----

  int _r16(int addr) => vramData.getUint16(addr & 0x7fffe);

  void _draw() {
    edsr &= ~2;
    _pixels = 0;

    int addr = 0;
    int returnAddr = -1;
    int commands = 0;

    for (; commands < 20000; commands++) {
      final ctrl = _r16(addr);
      copr = addr.shr3;

      if (ctrl.bit15) {
        break;
      }

      if (!ctrl.bit14) {
        _execCommand(addr, ctrl);
      }

      lopr = addr.shr3;

      final link = _r16(addr + 2).shl3;
      switch (ctrl.shr12.mask2) {
        case 0:
          addr += 0x20;
          break;
        case 1:
          addr = link;
          break;
        case 2:
          if (returnAddr < 0) {
            returnAddr = addr + 0x20;
          }
          addr = link;
          break;
        case 3:
          if (returnAddr >= 0) {
            addr = returnAddr;
            returnAddr = -1;
          } else {
            addr += 0x20;
          }
          break;
      }
      addr &= 0x7ffff;
    }

    edsr |= 2;
    _drawEndWait = 200 + commands * 20 + _pixels.shr1;
  }

  // command parameters
  int _pmod = 0;
  int _colr = 0;
  int _srca = 0;
  int _texW = 0, _texH = 0;
  int _dir = 0;
  final _grd = Int32List(12); // gouraud rgb for A, B, C, D

  void _execCommand(int addr, int ctrl) {
    final cmd = ctrl.mask4;

    _pmod = _r16(addr + 0x04);
    _colr = _r16(addr + 0x06);
    _srca = _r16(addr + 0x08).shl3;
    final size = _r16(addr + 0x0a);
    _texW = size.shr8.mask6 * 8;
    _texH = size.mask8;
    _dir = ctrl.shr4.mask2;

    final xa = _r16(addr + 0x0c).rel11;
    final ya = _r16(addr + 0x0e).rel11;
    final xb = _r16(addr + 0x10).rel11;
    final yb = _r16(addr + 0x12).rel11;
    final xc = _r16(addr + 0x14).rel11;
    final yc = _r16(addr + 0x16).rel11;
    final xd = _r16(addr + 0x18).rel11;
    final yd = _r16(addr + 0x1a).rel11;

    if (_pmod.mask3 >= 4) {
      final g = _r16(addr + 0x1c).shl3;
      for (int i = 0; i < 4; i++) {
        final c = _r16(g + i * 2);
        _grd[i * 3 + 0] = c.mask5;
        _grd[i * 3 + 1] = c.shr5.mask5;
        _grd[i * 3 + 2] = c.shr10.mask5;
      }
    }

    switch (cmd) {
      case 0x0: // normal sprite
        final x0 = xa + _localX;
        final y0 = ya + _localY;
        _drawRect(x0, y0, x0 + _texW - 1, y0 + _texH - 1);
        break;
      case 0x1: // scaled sprite
        _scaledSprite(ctrl, xa, ya, xb, yb, xc, yc);
        break;
      case 0x2 || 0x3: // distorted sprite
        _drawQuad(xa + _localX, ya + _localY, xb + _localX, yb + _localY,
            xc + _localX, yc + _localY, xd + _localX, yd + _localY, true);
        break;
      case 0x4: // polygon
        _drawQuad(xa + _localX, ya + _localY, xb + _localX, yb + _localY,
            xc + _localX, yc + _localY, xd + _localX, yd + _localY, false);
        break;
      case 0x5 || 0x7: // polyline
        final xs = [xa, xb, xc, xd];
        final ys = [ya, yb, yc, yd];
        final gi = [0, 1, 2, 3];
        for (int i = 0; i < 4; i++) {
          final j = (i + 1).mask2;
          _drawLine(xs[i] + _localX, ys[i] + _localY, xs[j] + _localX,
              ys[j] + _localY, gi[i], gi[j]);
        }
        break;
      case 0x6: // line
        _drawLine(xa + _localX, ya + _localY, xb + _localX, yb + _localY, 0, 1);
        break;
      case 0x8 || 0xb: // user clipping
        _userX1 = _r16(addr + 0x0c).mask10;
        _userY1 = _r16(addr + 0x0e).mask9;
        _userX2 = _r16(addr + 0x14).mask10;
        _userY2 = _r16(addr + 0x16).mask9;
        break;
      case 0x9: // system clipping
        _sysClipX = _r16(addr + 0x14).mask10;
        _sysClipY = _r16(addr + 0x16).mask9;
        break;
      case 0xa: // local coordinate
        _localX = _r16(addr + 0x0c).rel11;
        _localY = _r16(addr + 0x0e).rel11;
        break;
    }
  }

  void _scaledSprite(int ctrl, int xa, int ya, int xb, int yb, int xc, int yc) {
    final zp = ctrl.shr8.mask4;
    int x0, y0, x1, y1;

    if (zp == 0) {
      x0 = xa;
      y0 = ya;
      x1 = xc;
      y1 = yc;
    } else {
      final w = xb;
      final h = yb;
      x0 = switch (zp.mask2) {
        2 => xa - w ~/ 2,
        3 => xa - w,
        _ => xa,
      };
      y0 = switch (zp.shr2.mask2) {
        2 => ya - h ~/ 2,
        3 => ya - h,
        _ => ya,
      };
      x1 = x0 + w;
      y1 = y0 + h;
    }

    _drawRect(x0 + _localX, y0 + _localY, x1 + _localX, y1 + _localY);
  }

  // ---- texel fetch ----

  int _endCodes = 0;

  static const _transparent = -1;
  static const _endCode = -2;

  @pragma('vm:prefer-inline')
  int _texel(int u, int v) {
    final mode = _pmod.shr3.mask3;
    final ecd = _pmod.bit7;
    final spd = _pmod.bit6;

    switch (mode) {
      case 0 || 1:
        final b = vram[(_srca + (v * _texW + u).shr1) & 0x7ffff];
        final dot = u.bit0 ? b.mask4 : b.shr4;
        if (dot == 0xf && !ecd) return _endCode;
        if (dot == 0 && !spd) return _transparent;
        return mode == 0 ? (_colr & 0xfff0) | dot : _r16(_colr.shl3 + dot * 2);
      case 2 || 3 || 4:
        final dot = vram[(_srca + v * _texW + u) & 0x7ffff];
        if (dot == 0xff && !ecd) return _endCode;
        if (dot == 0 && !spd) return _transparent;
        return switch (mode) {
          2 => (_colr & 0xffc0) | dot.mask6,
          3 => (_colr & 0xff80) | dot.mask7,
          _ => (_colr & 0xff00) | dot,
        };
      default:
        final dot = _r16(_srca + (v * _texW + u) * 2);
        if (dot == 0x7fff && !ecd) return _endCode;
        if (dot == 0 && !spd) return _transparent;
        return dot;
    }
  }

  // ---- pixel output ----

  @pragma('vm:prefer-inline')
  bool _clipped(int x, int y) {
    if (x < 0 || y < 0 || x > _sysClipX || y > _sysClipY) {
      return true;
    }
    if (x >= (eightBit ? fbWidth * 2 : fbWidth) ||
        (fbcr.bit3 ? y.shr1 : y) >= fbHeight) {
      return true;
    }
    if (_pmod.bit10) {
      final inside =
          x >= _userX1 && x <= _userX2 && y >= _userY1 && y <= _userY2;
      return _pmod.bit9 ? inside : !inside;
    }
    return false;
  }

  static int _half(int c) => c.shr1 & 0x3def | 0x8000;

  static int _avg(int a, int b) => ((a & 0x7bde) + (b & 0x7bde)).shr1 | 0x8000;

  // gouraud values in 5.16 fixed point
  int _gr = 0, _gg = 0, _gb = 0;

  @pragma('vm:prefer-inline')
  void _plot(int x, int y, int color) {
    if (_clipped(x, y)) {
      return;
    }
    if (_pmod.bit8 && (x ^ y).bit0) {
      return; // mesh
    }
    // FBCR DIE: the lines are of the 448-line screen, and the frame buffer
    // holds the lines of the field that DIL selects
    if (fbcr.bit3) {
      if (y.bit0 != fbcr.bit2) return;
      y = y.shr1;
    }

    _pixels++;
    final fb = drawFb;
    if (eightBit) {
      // no color calculation on 8-bit pixels
      final i = y * fbWidth + x.shr1;
      fb[i] = x.bit0
          ? fb[i] & 0xff00 | color.mask8
          : fb[i].mask8 | color.mask8.shl8;
      return;
    }
    final i = y * fbWidth + x;

    if (_pmod.bit15) {
      fb[i] |= 0x8000; // MSB on
      return;
    }

    final calc = _pmod.mask3;
    if (calc == 0 || !color.bit15) {
      if (calc == 1) return; // shadow on palette data: nothing
      fb[i] = color;
      return;
    }

    if (calc >= 4) {
      color = _gouraud(color);
    }

    switch (calc) {
      case 1: // shadow
        final d = fb[i];
        if (d.bit15) fb[i] = _half(d);
        return;
      case 2 || 6: // half luminance
        fb[i] = _half(color);
        return;
      case 3 || 7: // half transparent
        final d = fb[i];
        fb[i] = d.bit15 ? _avg(color, d) : color;
        return;
      default:
        fb[i] = color;
    }
  }

  int _gouraud(int c) {
    int r = c.mask5 + _gr.shr16 - 16;
    int g = c.shr5.mask5 + _gg.shr16 - 16;
    int b = c.shr10.mask5 + _gb.shr16 - 16;
    r = r < 0 ? 0 : (r > 31 ? 31 : r);
    g = g < 0 ? 0 : (g > 31 ? 31 : g);
    b = b < 0 ? 0 : (b > 31 ? 31 : b);
    return 0x8000 | b.shl10 | g.shl5 | r;
  }

  // ---- primitives ----

  void _drawRect(int x0, int y0, int x1, int y1) {
    bool hf = _dir.bit0, vf = _dir.bit1;
    if (x1 < x0) {
      final t = x0;
      x0 = x1;
      x1 = t;
      hf = !hf;
    }
    if (y1 < y0) {
      final t = y0;
      y0 = y1;
      y1 = t;
      vf = !vf;
    }

    if (_texW == 0 || _texH == 0) {
      return;
    }

    final dw = x1 - x0 + 1;
    final dh = y1 - y0 + 1;
    final gouraud = _pmod.mask3 >= 4;

    final ys = y0 < 0 ? 0 : y0;
    final ye = y1 > _sysClipY ? _sysClipY : y1;
    final xs = x0 < 0 ? 0 : x0;
    final xe = x1 > _sysClipX ? _sysClipX : x1;

    for (int y = ys; y <= ye; y++) {
      int v = (y - y0) * _texH ~/ dh;
      if (vf) v = _texH - 1 - v;

      _endCodes = 0;
      final ty = (y - y0) * 65536 ~/ dh;

      // Start at x0 even when it is clipped: end codes are counted from the
      // sprite's original left edge, so jumping straight to xs changes them.
      // u = (x - x0) * _texW ~/ dw, stepped without a division per dot
      final texW = _texW;
      int textureColumn = 0, textureRemainder = 0;
      for (int x = x0; x <= xe; x++) {
        int u = textureColumn;
        textureRemainder += texW;
        while (textureRemainder >= dw) {
          textureRemainder -= dw;
          textureColumn++;
        }
        if (hf) u = texW - 1 - u;

        final t = _texel(u, v);
        if (t == _endCode) {
          if (++_endCodes >= 2) break;
          continue;
        }
        if (x < xs || t == _transparent) {
          continue;
        }

        if (gouraud) {
          final tx = (x - x0) * 65536 ~/ dw;
          _bilinearGouraud(tx, ty);
        }
        _plot(x, y, t);
      }
    }
  }

  void _bilinearGouraud(int tx, int ty) {
    int lerp(int a, int b, int t) => a.shl16 + (b - a) * t;
    int ch(int c) {
      final top = lerp(_grd[c], _grd[3 + c], tx);
      final bottom = lerp(_grd[9 + c], _grd[6 + c], tx);
      return top + ((bottom - top) * ty).shr16;
    }

    _gr = ch(0);
    _gg = ch(1);
    _gb = ch(2);
  }

  void _drawQuad(int ax, int ay, int bx, int by, int cx, int cy, int dx, int dy,
      bool textured) {
    if (textured && (_texW == 0 || _texH == 0)) {
      return;
    }

    // left edge A->D, right edge B->C
    final lenL = _max((dx - ax).abs(), (dy - ay).abs());
    final lenR = _max((cx - bx).abs(), (cy - by).abs());
    final steps = _max(_max(lenL, lenR), 1);

    // skip quads fully out of the clip area
    final minX = _min(_min(ax, bx), _min(cx, dx));
    final maxX = _max(_max(ax, bx), _max(cx, dx));
    final minY = _min(_min(ay, by), _min(cy, dy));
    final maxY = _max(_max(ay, by), _max(cy, dy));
    if (maxX < 0 || maxY < 0 || minX > _sysClipX || minY > _sysClipY) {
      return;
    }

    final gouraud = _pmod.mask3 >= 4;

    for (int i = 0; i <= steps; i++) {
      final t = i * 65536 ~/ steps;
      final lx = ax + ((dx - ax) * t + 0x8000).shr16;
      final ly = ay + ((dy - ay) * t + 0x8000).shr16;
      final rx = bx + ((cx - bx) * t + 0x8000).shr16;
      final ry = by + ((cy - by) * t + 0x8000).shr16;

      int v = textured ? (i * _texH) ~/ (steps + 1) : 0;
      if (_dir.bit1) v = _texH - 1 - v;

      int glR = 0, glG = 0, glB = 0, grR = 0, grG = 0, grB = 0;
      if (gouraud) {
        glR = _grd[0].shl16 + (_grd[9] - _grd[0]) * t;
        glG = _grd[1].shl16 + (_grd[10] - _grd[1]) * t;
        glB = _grd[2].shl16 + (_grd[11] - _grd[2]) * t;
        grR = _grd[3].shl16 + (_grd[6] - _grd[3]) * t;
        grG = _grd[4].shl16 + (_grd[7] - _grd[4]) * t;
        grB = _grd[5].shl16 + (_grd[8] - _grd[5]) * t;
      }

      _texLine(
          lx, ly, rx, ry, v, textured, gouraud, glR, glG, glB, grR, grG, grB);
    }
  }

  // draws a line of a quad, u runs 0 -> texW-1 along the line
  void _texLine(int x0, int y0, int x1, int y1, int v, bool textured,
      bool gouraud, int glR, int glG, int glB, int grR, int grG, int grB) {
    final n = _max((x1 - x0).abs(), (y1 - y0).abs());
    final sx = x1 > x0 ? 1 : -1;
    final sy = y1 > y0 ? 1 : -1;
    final adx = (x1 - x0).abs();
    final ady = (y1 - y0).abs();

    _endCodes = 0;
    int px = x0, py = y0;
    int err = 0;

    for (int j = 0; j <= n; j++) {
      int color;
      if (textured) {
        int u = n == 0 ? 0 : j * _texW ~/ (n + 1);
        if (_dir.bit0) u = _texW - 1 - u;
        color = _texel(u, v);
        if (color == _endCode) {
          if (++_endCodes >= 2) return;
          color = _transparent;
        }
      } else {
        color = _colr;
      }

      if (color != _transparent) {
        if (gouraud) {
          final t = n == 0 ? 0 : j * 65536 ~/ n;
          _gr = glR + ((grR - glR).shr8 * t).shr8;
          _gg = glG + ((grG - glG).shr8 * t).shr8;
          _gb = glB + ((grB - glB).shr8 * t).shr8;
        }
        _plot(px, py, color);
      }

      // step along the major axis, with an extra dot on diagonal steps
      if (adx >= ady) {
        px += sx;
        err += ady;
        if (err * 2 >= adx && adx != 0) {
          err -= adx;
          if (color != _transparent) _plot(px, py, color);
          py += sy;
        }
      } else {
        py += sy;
        err += adx;
        if (err * 2 >= ady && ady != 0) {
          err -= ady;
          if (color != _transparent) _plot(px, py, color);
          px += sx;
        }
      }
    }
  }

  void _drawLine(int x0, int y0, int x1, int y1, int g0, int g1) {
    final gouraud = _pmod.mask3 >= 4;
    _texLine(
        x0,
        y0,
        x1,
        y1,
        0,
        false,
        gouraud,
        _grd[g0 * 3].shl16,
        _grd[g0 * 3 + 1].shl16,
        _grd[g0 * 3 + 2].shl16,
        _grd[g1 * 3].shl16,
        _grd[g1 * 3 + 1].shl16,
        _grd[g1 * 3 + 2].shl16);
  }

  static int _max(int a, int b) => a > b ? a : b;
  static int _min(int a, int b) => a < b ? a : b;

  String dump() =>
      "vdp1: tvmr:${tvmr.x2} fbcr:${fbcr.x2} ptmr:$ptmr edsr:${edsr.x2} lopr:${lopr.x4} copr:${copr.x4} draw:$_drawIndex";
}
