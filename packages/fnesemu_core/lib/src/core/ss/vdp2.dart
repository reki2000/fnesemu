import 'dart:typed_data';

import '../../types.dart';
import '../../util/int.dart';
import '../../video_debug.dart';
import 'vdp1.dart';

part 'vdp2_rotation.dart';
part 'video_debug.dart';

/// map configuration of a scroll screen (NBG / RBG)
class _MapCfg {
  int colorMode = 0; // 0:16, 1:256, 2:2048, 3:32K, 4:16M
  bool bitmap = false;
  int bitmapW = 512, bitmapH = 256;
  int bitmapAddr = 0;
  int bitmapPalette = 0;
  bool char16 = false; // 2x2 cells
  int pnSize = 2; // pattern name data size in bytes
  int pncn = 0; // pattern name control register
  int planeW = 1, planeH = 1; // pages per plane
  int mapW = 2; // planes per map row (2 for NBG, 4 for RBG)
  final planeAddr = List<int>.filled(16, 0);
  int craOffset = 0;
  bool transparentEnabled = true;
  int priority = 0;
  bool ccEnabled = false;
  int sfprMode = 0;

  @pragma('vm:prefer-inline')
  int get pageBytes =>
      pnSize == 2 ? (char16 ? 0x800 : 0x2000) : (char16 ? 0x1000 : 0x4000);

  int get pageDots => 512;
  @pragma('vm:prefer-inline')
  int get planeDotsW => planeW * 512;
  @pragma('vm:prefer-inline')
  int get planeDotsH => planeH * 512;
  @pragma('vm:prefer-inline')
  int get mapDotsW => planeDotsW * mapW;
  @pragma('vm:prefer-inline')
  int get mapDotsH => planeDotsH * mapW;

  // the address of a plane from its map number
  int planeAddrOf(int mapNum) {
    final pages = planeW * planeH;
    final shift = pages == 1 ? 0 : (pages == 2 ? 1 : 2);
    final mask = pnSize == 2 ? (char16 ? 0xff : 0x3f) : (char16 ? 0x7f : 0x1f);
    return ((mapNum & mask) >> shift) * pages * pageBytes;
  }
}

/// VDP2: scroll screens, priority and color calculation
class Vdp2 {
  late Vdp1 vdp1;

  final vram = Uint8List(0x80000);
  late final vramData = ByteData.sublistView(vram);

  final cram = Uint8List(0x1000);
  late final cramData = ByteData.sublistView(cram);

  final regs = Uint16List(0x100);

  // color RAM decoded into 0x00bbggrr
  final _colors = Int32List(2048);

  // timing states updated by the core
  int line = 0;
  bool vblank = false;
  bool hblank = false;
  bool oddField = false;
  int frame = 0;

  static const scanlinesNtsc = 263;

  static const maxWidth = 704;
  static const maxHeight = 256;

  var _frameBuffer = Uint32List(320 * 224);
  int _fbWidth = 320;
  int _fbHeight = 224;

  ImageBuffer get imageBuffer => ImageBuffer(_fbWidth, _fbHeight, _frameBuffer,
      displayWidth_: _fbWidth >= 640 ? _fbWidth ~/ 2 : _fbWidth);

  void reset() {
    regs.fillRange(0, regs.length, 0);
    line = 0;
    vblank = false;
    hblank = false;
    frame = 0;
  }

  // register accessors

  int reg(int addr) => regs[addr.shr1];

  int get tvmd => regs[0x00 >> 1];
  bool get displayOn => tvmd.bit15;

  int get width => switch (tvmd.mask3) {
        0 || 4 => 320,
        1 || 5 => 352,
        2 || 6 => 640,
        _ => 704,
      };

  /// number of display lines per field
  int get displayLines => switch (tvmd.shr4.mask2) {
        0 => 224,
        1 => 240,
        _ => 256,
      };

  /// double-density interlace (LSMD = 3): both fields are rendered at once
  bool get doubleDensity => tvmd.shr6.mask2 == 3;

  /// height of the output image
  int get height => doubleDensity ? displayLines * 2 : displayLines;

  int get cramMode => regs[0x0e >> 1].shr12.mask2;

  int readReg(int addr) {
    return switch (addr) {
      0x004 => (vblank ? 0x08 : 0) |
          (hblank ? 0x04 : 0) |
          (oddField ? 0x02 : 0), // TVSTAT (NTSC)
      0x006 => regs[0x06 >> 1] & 0x8000, // VRSIZE, version 0
      0x008 => 0, // HCNT
      0x00a => line.mask10, // VCNT
      _ => regs[addr.shr1],
    };
  }

  void writeReg(int addr, int data) {
    regs[addr.shr1] = data;
    if (addr == 0x00e) {
      _cramMask = cramMode == 1 ? 0x7ff : 0x3ff;
      _rebuildColors();
    }
  }

  int readCram16(int addr) => cramData.getUint16(_cramAddr(addr) & 0xffe);

  void writeCram16(int addr, int data) {
    final a = _cramAddr(addr) & 0xffe;
    cramData.setUint16(a, data);
    _updateColor(a);
  }

  void writeCram8(int addr, int data) {
    final a = _cramAddr(addr);
    cram[a] = data;
    _updateColor(a & 0xffe);
  }

  // in mode 0, the second half of color ram mirrors the first half
  int _cramAddr(int addr) => cramMode == 0 ? addr.mask11 : addr.mask12;

  @pragma('vm:prefer-inline')
  static int _rgb555(int c) {
    final r = c.mask5, g = c.shr5.mask5, b = c.shr10.mask5;
    return (b.shl3 | b.shr2).shl16 | (g.shl3 | g.shr2).shl8 | (r.shl3 | r.shr2);
  }

  void _updateColor(int a) {
    if (cramMode == 2) {
      final i = a.shr2;
      final c = cramData.getUint32(i.shl2);
      // bits 23-16: B, 15-8: G, 7-0: R
      _colors[i.mask10] = c.mask24;
    } else {
      _colors[a.shr1.mask11] = _rgb555(cramData.getUint16(a));
    }
  }

  void _rebuildColors() {
    if (cramMode == 2) {
      for (int i = 0; i < 1024; i++) {
        _colors[i] = cramData.getUint32(i.shl2).mask24;
      }
    } else {
      for (int i = 0; i < 2048; i++) {
        _colors[i] = _rgb555(cramData.getUint16(i.shl1));
      }
    }
  }

  int _cramMask = 0x3ff;

  @pragma('vm:prefer-inline')
  int _color(int index) => _colors[index & _cramMask];

  // line buffers: bits 23-0 color, 24-26 priority, 27 color calculation enabled
  static const _layerSprite = 0;
  static const _layerRbg0 = 1;
  static const _layerNbg0 = 2;

  final _lines = List.generate(6, (_) => Int32List(maxWidth));
  final _spriteRatio = Uint8List(maxWidth);

  static const _ccBit = 1 << 27;

  /// render one display line
  void renderLine(int y) {
    final w = width;
    final h = height;

    if (w != _fbWidth || h != _fbHeight) {
      _fbWidth = w;
      _fbHeight = h;
      _frameBuffer = Uint32List(w * h);
    }

    if (y >= h) {
      return;
    }

    final out = y * w;

    if (!displayOn) {
      _frameBuffer.fillRange(out, out + w, 0xff000000);
      return;
    }

    final bgon = reg(0x20);
    _activeCount = 0;

    // front to back: sprite, RBG0, NBG0-3 (tie-break order of equal priority)
    if (_renderSprite(y, w, _lines[_layerSprite])) {
      _active[_activeCount++] = _layerSprite;
    }

    if (bgon.bit4 && reg(0xfc).mask3 != 0) {
      final buf = _lines[_layerRbg0];
      buf.fillRange(0, w, 0);
      _renderRbg0(y, w, buf);
      _active[_activeCount++] = _layerRbg0;
    }

    for (int n = 0; n < 4; n++) {
      if (bgon & (1 << n) != 0 && !(n == 0 && bgon.bit5)) {
        final buf = _lines[_layerNbg0 + n];
        if (_renderNbg(n, y, w, buf)) {
          _active[_activeCount++] = _layerNbg0 + n;
        }
      }
    }

    _compose(y, w, out);
  }

  final _active = Int32List(6);
  final _activeBufs = List<Int32List>.filled(6, Int32List(0));
  int _activeCount = 0;

  // ---- NBG ----

  final _cfg = _MapCfg();
  final _rotA = _RotParam();
  final _rotB = _RotParam();

  void _setupNbg(int n, _MapCfg cfg) {
    final chctla = reg(0x28);
    final chctlb = reg(0x2a);

    switch (n) {
      case 0:
        cfg.colorMode = chctla.shr4.mask3;
        cfg.bitmap = chctla.bit1;
        cfg.char16 = chctla.bit0;
        _setBitmapSize(cfg, chctla.shr2.mask2);
        cfg.bitmapPalette = reg(0x2c).mask3;
        break;
      case 1:
        cfg.colorMode = chctla.shr12.mask2;
        cfg.bitmap = chctla.bit9;
        cfg.char16 = chctla.bit8;
        _setBitmapSize(cfg, chctla.shr10.mask2);
        cfg.bitmapPalette = reg(0x2c).shr8.mask3;
        break;
      case 2:
        cfg.colorMode = chctlb.bit1 ? 1 : 0;
        cfg.bitmap = false;
        cfg.char16 = chctlb.bit0;
        break;
      default:
        cfg.colorMode = chctlb.bit5 ? 1 : 0;
        cfg.bitmap = false;
        cfg.char16 = chctlb.bit4;
        break;
    }

    cfg.pncn = reg(0x30 + n * 2);
    cfg.pnSize = cfg.pncn.bit15 ? 2 : 4;

    final plsz = (reg(0x3a) >> (n * 2)).mask2;
    cfg.planeW = plsz == 0 ? 1 : 2;
    cfg.planeH = plsz == 3 ? 2 : 1;
    cfg.mapW = 2;

    final mapOffset = (reg(0x3c) >> (n * 4)).mask3;
    final ab = reg(0x40 + n * 4);
    final cd = reg(0x42 + n * 4);
    final nums = [ab.mask6, ab.shr8.mask6, cd.mask6, cd.shr8.mask6];
    for (int i = 0; i < 4; i++) {
      cfg.planeAddr[i] = cfg.planeAddrOf(mapOffset.shl6 | nums[i]);
    }

    cfg.bitmapAddr = mapOffset * 0x20000;
    cfg.craOffset = (reg(0xe4) >> (n * 4)).mask3.shl8;
    cfg.transparentEnabled = reg(0x20) & (0x100 << n) == 0;
    cfg.priority = n < 2
        ? (reg(0xf8) >> (n * 8)).mask3
        : (reg(0xfa) >> ((n - 2) * 8)).mask3;
    cfg.ccEnabled = reg(0xec) & (1 << n) != 0;
    cfg.sfprMode = (reg(0xea) >> (n * 2)).mask2;
  }

  static void _setBitmapSize(_MapCfg cfg, int size) {
    cfg.bitmapW = size.bit1 ? 1024 : 512;
    cfg.bitmapH = size.bit0 ? 512 : 256;
  }

  bool _renderNbg(int n, int y, int w, Int32List buf) {
    final cfg = _cfg;
    _setupNbg(n, cfg);

    if (cfg.priority == 0 && cfg.sfprMode != 1) {
      return false;
    }

    // scroll position in 16.8 fixed point
    int sx, sy, dx;
    if (n < 2) {
      final base = 0x70 + n * 0x10;
      sx = reg(base).mask11.shl8 | reg(base + 2).shr8;
      sy = reg(base + 4).mask11.shl8 | reg(base + 6).shr8;
      dx = reg(base + 8).mask3.shl8 | reg(base + 10).shr8;
      int dy = reg(base + 12).mask3.shl8 | reg(base + 14).shr8;
      // zoom registers are 0 after reset: treat as 1.0
      if (dx == 0) dx = 0x100;
      if (dy == 0) dy = 0x100;
      sy += y * dy;

      // line scroll
      final scrctl = reg(0x9a) >> (n * 8);
      if (scrctl & 0x0e != 0) {
        final interval = 1 << scrctl.shr4.mask2;
        final tableAddr =
            (reg(0xa0 + n * 4).mask3.shl16 | reg(0xa2 + n * 4) & 0xfffe).shl1;
        final entrySize = (scrctl.bit1 ? 4 : 0) +
            (scrctl.bit2 ? 4 : 0) +
            (scrctl.bit3 ? 4 : 0);
        int addr = tableAddr + (y ~/ interval) * entrySize;
        if (scrctl.bit1) {
          sx += vramData.getUint32(addr & 0x7fffc).shr8 & 0x7ffff;
          addr += 4;
        }
        if (scrctl.bit2) {
          sy = reg(base + 4).mask11.shl8 | reg(base + 6).shr8;
          sy += vramData.getUint32(addr & 0x7fffc).shr8 & 0x7ffff;
          addr += 4;
        }
        if (scrctl.bit3) {
          dx = vramData.getUint32(addr & 0x7fffc).shr8.mask11;
        }
      }
    } else {
      final base = 0x90 + (n - 2) * 4;
      sx = reg(base).mask11.shl8;
      sy = (reg(base + 2).mask11 + y).shl8;
      dx = 0x100;
    }

    final py = sy.shr8;

    if (cfg.bitmap) {
      for (int x = 0; x < w; x++) {
        buf[x] = _bitmapDot(cfg, (sx + x * dx).shr8, py);
      }
      return true;
    }

    // same as _cellDot for each dot, with the per-line values hoisted
    final maskW = cfg.mapDotsW - 1;
    final cy = py & (cfg.mapDotsH - 1);
    final rowKey = cy.shr3.shl16;
    int lastKey = -1;
    int cellDy = 0;
    for (int x = 0; x < w; x++) {
      final cx = (sx + x * dx).shr8 & maskW;
      final key = rowKey | cx.shr3;
      if (key != lastKey) {
        lastKey = key;
        _setupCell(cfg, cx, cy);
        cellDy = _cellVf ? 7 - cy.mask3 : cy.mask3;
      }
      if (_cellPri == 0) {
        buf[x] = 0;
        continue;
      }
      final cellDx = _cellHf ? 7 - cx.mask3 : cx.mask3;
      buf[x] = _dot(cfg, _cellAddr, cellDx, cellDy, 8, _cellPalette, _cellPri);
    }
    _lastCellKey = lastKey;
    return true;
  }

  // ---- dot fetching ----

  // decoded state of the last 8x8 cell
  int _lastCellKey = -1;
  int _cellAddr = 0;
  int _cellPalette = 0;
  int _cellPri = 0;
  bool _cellHf = false, _cellVf = false;

  // pattern name decode results
  int _pnCharAddr = 0;
  int _pnPalette = 0;
  bool _pnHf = false, _pnVf = false;
  bool _pnSpr = false;

  void _decodePattern(_MapCfg cfg, int addr) {
    final pncn = cfg.pncn;
    int charNum;
    if (cfg.pnSize == 4) {
      final w0 = vramData.getUint16(addr & 0x7fffc);
      final w1 = vramData.getUint16((addr & 0x7fffc) + 2);
      charNum = w1.mask15;
      _pnHf = w0.bit14;
      _pnVf = w0.bit15;
      _pnSpr = w0.bit13;
      _pnPalette = cfg.colorMode == 0 ? w0.mask7 : w0 & 0x70;
    } else {
      final d = vramData.getUint16(addr & 0x7fffe);
      _pnSpr = pncn.bit9;
      _pnPalette = cfg.colorMode == 0
          ? d.shr12.mask4 | (pncn & 0xe0).shr1
          : d.shr8 & 0x70;

      if (!pncn.bit14) {
        _pnHf = d.bit10;
        _pnVf = d.bit11;
        charNum = cfg.char16
            ? d.mask10.shl2 | pncn.mask2 | (pncn & 0x1c).shl10
            : d.mask10 | pncn.mask5.shl10;
      } else {
        _pnHf = false;
        _pnVf = false;
        charNum = cfg.char16
            ? d.mask12.shl2 | pncn.mask2 | (pncn & 0x10).shl10
            : d.mask12 | (pncn & 0x1c).shl10;
      }
    }

    _pnCharAddr = charNum.mask14.shl5;
  }

  static const _cellBytes = [32, 64, 128, 128, 256, 256, 256, 256];

  @pragma('vm:prefer-inline')
  int _cellDot(_MapCfg cfg, int x, int y) {
    x &= cfg.mapDotsW - 1;
    y &= cfg.mapDotsH - 1;

    final key = y.shr3.shl16 | x.shr3;
    if (key != _lastCellKey) {
      _lastCellKey = key;
      _setupCell(cfg, x, y);
    }

    if (_cellPri == 0) {
      return 0;
    }

    final dx = _cellHf ? 7 - x.mask3 : x.mask3;
    final dy = _cellVf ? 7 - y.mask3 : y.mask3;
    return _dot(cfg, _cellAddr, dx, dy, 8, _cellPalette, _cellPri);
  }

  void _setupCell(_MapCfg cfg, int x, int y) {
    final planeW = cfg.planeDotsW;
    final planeH = cfg.planeDotsH;
    final plane = (y ~/ planeH) * cfg.mapW + (x ~/ planeW);
    final px = x & (planeW - 1);
    final py = y & (planeH - 1);
    final page = py.shr9 * cfg.planeW + px.shr9;
    final cx = px.mask9;
    final cy = py.mask9;

    final patternIndex =
        cfg.char16 ? cy.shr4 * 32 + cx.shr4 : cy.shr3 * 64 + cx.shr3;
    final patternAddr =
        cfg.planeAddr[plane] + page * cfg.pageBytes + patternIndex * cfg.pnSize;

    _decodePattern(cfg, patternAddr);

    int addr = _pnCharAddr;
    if (cfg.char16) {
      // select one of 2x2 cells, flips apply to the whole 16x16 character
      int subX = cx.shr3.mask1;
      int subY = cy.shr3.mask1;
      if (_pnHf) subX ^= 1;
      if (_pnVf) subY ^= 1;
      addr += (subY * 2 + subX) * _cellBytes[cfg.colorMode];
    }

    int pri = cfg.priority;
    if (cfg.sfprMode == 1) {
      pri = _pnSpr ? pri | 1 : pri & ~1;
    }

    _cellAddr = addr;
    _cellPalette = _pnPalette;
    _cellPri = pri;
    _cellHf = _pnHf;
    _cellVf = _pnVf;
  }

  @pragma('vm:prefer-inline')
  int _bitmapDot(_MapCfg cfg, int x, int y) {
    x &= cfg.bitmapW - 1;
    y &= cfg.bitmapH - 1;
    return _dot(cfg, cfg.bitmapAddr, x, y, cfg.bitmapW, cfg.bitmapPalette.shl4,
        cfg.priority);
  }

  /// fetches a dot from character / bitmap data at (x, y), returns packed pixel
  @pragma('vm:prefer-inline')
  int _dot(
      _MapCfg cfg, int base, int x, int y, int stride, int palette, int pri) {
    int color;
    switch (cfg.colorMode) {
      case 0:
        final b = vram[(base + (y * stride + x).shr1) & 0x7ffff];
        final d = x.bit0 ? b.mask4 : b.shr4;
        if (d == 0 && cfg.transparentEnabled) return 0;
        color = _color(cfg.craOffset + palette * 16 + d);
        break;
      case 1:
        final d = vram[(base + y * stride + x) & 0x7ffff];
        if (d == 0 && cfg.transparentEnabled) return 0;
        color = _color(cfg.craOffset + (palette & 0x70) * 16 + d);
        break;
      case 2:
        final d =
            vramData.getUint16((base + (y * stride + x) * 2) & 0x7fffe).mask11;
        if (d == 0 && cfg.transparentEnabled) return 0;
        color = _color(cfg.craOffset + d);
        break;
      case 3:
        final d = vramData.getUint16((base + (y * stride + x) * 2) & 0x7fffe);
        if (!d.bit15 && cfg.transparentEnabled) return 0;
        color = _rgb555(d);
        break;
      default:
        final d = vramData.getUint32((base + (y * stride + x) * 4) & 0x7fffc);
        if (!d.bit31 && cfg.transparentEnabled) return 0;
        color = d.mask24;
        break;
    }

    return pri.shl24 | (cfg.ccEnabled ? _ccBit : 0) | color;
  }

  // ---- sprite ----

  final _sprPri = Int32List(8);
  final _sprRatio = Int32List(8);

  /// renders the sprite layer, returns false when nothing can be displayed
  bool _renderSprite(int y, int w, Int32List buf) {
    final spctl = reg(0xe0);
    final type = spctl.mask4;
    final rgbMixed = spctl.bit5;
    final ccCond = spctl.shr12.mask2;
    final ccNum = spctl.shr8.mask3;
    final ccEnabled = reg(0xec).bit6;
    final craOffset = reg(0xe6).shr4.mask3.shl8;

    int anyPri = 0;
    for (int i = 0; i < 8; i++) {
      _sprPri[i] = (reg(0xf0 + i.shr1 * 2) >> (i.bit0 ? 8 : 0)).mask3;
      _sprRatio[i] = (reg(0x100 + i.shr1 * 2) >> (i.bit0 ? 8 : 0)).mask5;
      anyPri |= _sprPri[i];
    }
    if (anyPri == 0) {
      return false;
    }

    final fb = vdp1.displayFb;
    const fbWidth = Vdp1.fbWidth;
    final hiRes = w >= 640;

    // the frame buffer holds one field in double-density interlace
    if (doubleDensity) {
      y >>= 1;
    }

    if (y >= Vdp1.fbHeight) {
      buf.fillRange(0, w, 0);
      return true;
    }

    final rowBase = y * fbWidth;
    final rgbPri = _sprPri[0];
    final rgbCc = ccEnabled && _spriteCc(ccCond, ccNum, rgbPri, true);

    for (int x = 0; x < w; x++) {
      final fx = hiRes ? x.shr1 : x;
      final d = fb[rowBase + (fx & (fbWidth - 1))];

      if (d == 0) {
        buf[x] = 0;
        continue;
      }

      if (rgbMixed && d.bit15) {
        // RGB direct color
        _spriteRatio[x] = _sprRatio[0];
        buf[x] =
            rgbPri == 0 ? 0 : rgbPri.shl24 | (rgbCc ? _ccBit : 0) | _rgb555(d);
        continue;
      }

      int prIndex = 0, ccIndex = 0, dc = 0;
      switch (type) {
        case 0:
          prIndex = d.shr14.mask2;
          ccIndex = d.shr11.mask3;
          dc = d.mask11;
          break;
        case 1:
          prIndex = d.shr13.mask3;
          ccIndex = d.shr11.mask2;
          dc = d.mask11;
          break;
        case 2:
          prIndex = d.shr14.mask1;
          ccIndex = d.shr11.mask3;
          dc = d.mask11;
          break;
        case 3:
          prIndex = d.shr13.mask2;
          ccIndex = d.shr11.mask2;
          dc = d.mask11;
          break;
        case 4:
          prIndex = d.shr13.mask2;
          ccIndex = d.shr10.mask3;
          dc = d.mask10;
          break;
        case 5:
          prIndex = d.shr12.mask3;
          ccIndex = d.shr11.mask1;
          dc = d.mask11;
          break;
        case 6:
          prIndex = d.shr12.mask3;
          ccIndex = d.shr10.mask2;
          dc = d.mask10;
          break;
        case 7:
          prIndex = d.shr12.mask3;
          ccIndex = d.shr9.mask3;
          dc = d.mask9;
          break;
        case 8:
          prIndex = d.shr7.mask1;
          dc = d.mask7;
          break;
        case 9:
          prIndex = d.shr7.mask1;
          ccIndex = d.shr6.mask1;
          dc = d.mask6;
          break;
        case 10:
          prIndex = d.shr6.mask2;
          dc = d.mask6;
          break;
        case 11:
          ccIndex = d.shr6.mask2;
          dc = d.mask6;
          break;
        case 12:
          prIndex = d.shr7.mask1;
          dc = d.mask8;
          break;
        case 13:
          prIndex = d.shr7.mask1;
          ccIndex = d.shr6.mask1;
          dc = d.mask8;
          break;
        case 14:
          prIndex = d.shr6.mask2;
          dc = d.mask8;
          break;
        default:
          ccIndex = d.shr6.mask2;
          dc = d.mask8;
          break;
      }

      if (type >= 8 && d.mask8 == 0) {
        buf[x] = 0;
        continue;
      }

      final pri = _sprPri[prIndex];
      if (pri == 0) {
        buf[x] = 0;
        continue;
      }

      final cc = ccEnabled && _spriteCc(ccCond, ccNum, pri, d.bit15);
      _spriteRatio[x] = _sprRatio[ccIndex];
      buf[x] = pri.shl24 | (cc ? _ccBit : 0) | _color(craOffset + dc);
    }
    return true;
  }

  static bool _spriteCc(int cond, int num, int pri, bool msb) => switch (cond) {
        0 => pri <= num,
        1 => pri == num,
        2 => pri >= num,
        _ => msb,
      };

  // ---- composition ----

  int _backColor(int y) {
    final bktau = reg(0xac);
    int addr = (bktau.mask3.shl16 | reg(0xae)).shl1;
    if (bktau.bit15) {
      addr += y * 2;
    }
    return _rgb555(vramData.getUint16(addr & 0x7fffe));
  }

  static const _layerOffsetBits = [0x40, 0x10, 0x01, 0x02, 0x04, 0x08];
  static const _layerRatioRegs = [0, 0x10c, 0x108, 0x108, 0x10a, 0x10a];
  static const _layerRatioShift = [0, 0, 0, 8, 0, 8];

  // color offset per layer (index 6: back screen), 0x7fffffff: disabled
  final _offR = Int32List(7), _offG = Int32List(7), _offB = Int32List(7);
  final _offOn = List<bool>.filled(7, false);
  final _ratios = Int32List(6);

  void _setupOffsets() {
    final en = reg(0x110);
    final sel = reg(0x112);
    for (int l = 0; l < 7; l++) {
      final bit = l == 6 ? 0x20 : _layerOffsetBits[l];
      _offOn[l] = en & bit != 0;
      if (_offOn[l]) {
        final base = sel & bit != 0 ? 0x11a : 0x114;
        _offR[l] = reg(base).rel9;
        _offG[l] = reg(base + 2).rel9;
        _offB[l] = reg(base + 4).rel9;
      }
    }
    for (int l = 1; l < 6; l++) {
      _ratios[l] = (reg(_layerRatioRegs[l]) >> _layerRatioShift[l]).mask5;
    }
  }

  @pragma('vm:prefer-inline')
  int _offset(int l, int c) {
    if (!_offOn[l]) return c;
    int r = c.mask8 + _offR[l];
    int g = c.shr8.mask8 + _offG[l];
    int b = c.shr16.mask8 + _offB[l];
    r = r < 0 ? 0 : (r > 255 ? 255 : r);
    g = g < 0 ? 0 : (g > 255 ? 255 : g);
    b = b < 0 ? 0 : (b > 255 ? 255 : b);
    return b.shl16 | g.shl8 | r;
  }

  void _compose(int y, int w, int out) {
    _setupOffsets();
    final back = _offset(6, _backColor(y));
    final additive = reg(0xec).bit8;
    final fbuf = _frameBuffer;
    final n = _activeCount;

    if (n == 0) {
      fbuf.fillRange(out, out + w, 0xff000000 | back);
      return;
    }

    final active = _active;
    final bufs = _activeBufs;
    for (int i = 0; i < n; i++) {
      bufs[i] = _lines[active[i]];
    }

    for (int x = 0; x < w; x++) {
      int top = -1, topPri = 0, topPixel = 0;
      int second = -1, secondPri = 0, secondPixel = 0;

      for (int i = 0; i < n; i++) {
        final l = active[i];
        final p = bufs[i][x];
        if (p == 0) continue;
        final pri = p.shr24.mask3;
        if (pri > topPri) {
          second = top;
          secondPri = topPri;
          secondPixel = topPixel;
          top = l;
          topPri = pri;
          topPixel = p;
        } else if (pri > secondPri) {
          second = l;
          secondPri = pri;
          secondPixel = p;
        }
      }

      int color;
      if (top < 0) {
        color = back;
      } else {
        color = _offset(top, topPixel.mask24);

        if (topPixel & _ccBit != 0) {
          final under = second < 0 ? back : _offset(second, secondPixel.mask24);
          color = additive
              ? _add(color, under)
              : _blend(color, under,
                  top == _layerSprite ? _spriteRatio[x] : _ratios[top]);
        }
      }

      fbuf[out + x] = 0xff000000 | color;
    }
  }

  static int _add(int a, int b) {
    int r = a.mask8 + b.mask8;
    int g = a.shr8.mask8 + b.shr8.mask8;
    int bl = a.shr16.mask8 + b.shr16.mask8;
    if (r > 255) r = 255;
    if (g > 255) g = 255;
    if (bl > 255) bl = 255;
    return bl.shl16 | g.shl8 | r;
  }

  // ratio 0: top only, 31: almost bottom only
  static int _blend(int a, int b, int ratio) {
    final ta = 32 - ratio;
    final tb = ratio;
    final r = (a.mask8 * ta + b.mask8 * tb).shr5;
    final g = (a.shr8.mask8 * ta + b.shr8.mask8 * tb).shr5;
    final bl = (a.shr16.mask8 * ta + b.shr16.mask8 * tb).shr5;
    return bl.shl16 | g.shl8 | r;
  }

  String dump() {
    final r = List.generate(
        8, (i) => regs.sublist(i * 16, i * 16 + 16).map((e) => e.x4).join(" "));
    return "vdp2: line:$line ${width}x$height\n${r.join("\n")}";
  }
}
