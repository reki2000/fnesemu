import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';

import '../types.dart';
import 'vdp1.dart';

part 'vdp2_rotation.dart';

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

  int get pageBytes => pnSize == 2
      ? (char16 ? 0x800 : 0x2000)
      : (char16 ? 0x1000 : 0x4000);

  int get pageDots => 512;
  int get planeDotsW => planeW * 512;
  int get planeDotsH => planeH * 512;
  int get mapDotsW => planeDotsW * mapW;
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

  ImageBuffer get imageBuffer => ImageBuffer(
      _fbWidth, _fbHeight, _frameBuffer.buffer.asUint8List(),
      displayWidth_: _fbWidth >= 640 ? _fbWidth ~/ 2 : _fbWidth);

  void reset() {
    regs.fillRange(0, regs.length, 0);
    line = 0;
    vblank = false;
    hblank = false;
    frame = 0;
  }

  // register accessors

  int reg(int addr) => regs[addr >> 1];

  int get tvmd => regs[0x00 >> 1];
  bool get displayOn => tvmd.bit15;

  int get width => switch (tvmd & 7) {
        0 || 4 => 320,
        1 || 5 => 352,
        2 || 6 => 640,
        _ => 704,
      };

  /// number of display lines per field
  int get displayLines => switch ((tvmd >> 4) & 3) {
        0 => 224,
        1 => 240,
        _ => 256,
      };

  /// double-density interlace (LSMD = 3): both fields are rendered at once
  bool get doubleDensity => (tvmd >> 6) & 3 == 3;

  /// height of the output image
  int get height => doubleDensity ? displayLines * 2 : displayLines;

  int get cramMode => (regs[0x0e >> 1] >> 12) & 3;

  int readReg(int addr) {
    return switch (addr) {
      0x004 => (vblank ? 0x08 : 0) |
          (hblank ? 0x04 : 0) |
          (oddField ? 0x02 : 0), // TVSTAT (NTSC)
      0x006 => regs[0x06 >> 1] & 0x8000, // VRSIZE, version 0
      0x008 => 0, // HCNT
      0x00a => line & 0x3ff, // VCNT
      _ => regs[addr >> 1],
    };
  }

  void writeReg(int addr, int data) {
    regs[addr >> 1] = data;
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
  int _cramAddr(int addr) => cramMode == 0 ? addr & 0x7ff : addr & 0xfff;

  static int _rgb555(int c) {
    final r = c & 0x1f, g = (c >> 5) & 0x1f, b = (c >> 10) & 0x1f;
    return (b << 3 | b >> 2) << 16 | (g << 3 | g >> 2) << 8 | (r << 3 | r >> 2);
  }

  void _updateColor(int a) {
    if (cramMode == 2) {
      final i = a >> 2;
      final c = cramData.getUint32(i << 2);
      // bits 23-16: B, 15-8: G, 7-0: R
      _colors[i & 0x3ff] = c & 0xffffff;
    } else {
      _colors[(a >> 1) & 0x7ff] = _rgb555(cramData.getUint16(a));
    }
  }

  void _rebuildColors() {
    if (cramMode == 2) {
      for (int i = 0; i < 1024; i++) {
        _colors[i] = cramData.getUint32(i << 2) & 0xffffff;
      }
    } else {
      for (int i = 0; i < 2048; i++) {
        _colors[i] = _rgb555(cramData.getUint16(i << 1));
      }
    }
  }

  int _cramMask = 0x3ff;

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

    if (bgon.bit4 && reg(0xfc) & 7 != 0) {
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
        cfg.colorMode = (chctla >> 4) & 7;
        cfg.bitmap = chctla.bit1;
        cfg.char16 = chctla.bit0;
        _setBitmapSize(cfg, (chctla >> 2) & 3);
        cfg.bitmapPalette = reg(0x2c) & 7;
        break;
      case 1:
        cfg.colorMode = (chctla >> 12) & 3;
        cfg.bitmap = chctla.bit9;
        cfg.char16 = chctla.bit8;
        _setBitmapSize(cfg, (chctla >> 10) & 3);
        cfg.bitmapPalette = (reg(0x2c) >> 8) & 7;
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

    final plsz = (reg(0x3a) >> (n * 2)) & 3;
    cfg.planeW = plsz == 0 ? 1 : 2;
    cfg.planeH = plsz == 3 ? 2 : 1;
    cfg.mapW = 2;

    final mapOffset = (reg(0x3c) >> (n * 4)) & 7;
    final ab = reg(0x40 + n * 4);
    final cd = reg(0x42 + n * 4);
    final nums = [ab & 0x3f, (ab >> 8) & 0x3f, cd & 0x3f, (cd >> 8) & 0x3f];
    for (int i = 0; i < 4; i++) {
      cfg.planeAddr[i] = cfg.planeAddrOf(mapOffset << 6 | nums[i]);
    }

    cfg.bitmapAddr = mapOffset * 0x20000;
    cfg.craOffset = ((reg(0xe4) >> (n * 4)) & 7) << 8;
    cfg.transparentEnabled = reg(0x20) & (0x100 << n) == 0;
    cfg.priority = n < 2
        ? (reg(0xf8) >> (n * 8)) & 7
        : (reg(0xfa) >> ((n - 2) * 8)) & 7;
    cfg.ccEnabled = reg(0xec) & (1 << n) != 0;
    cfg.sfprMode = (reg(0xea) >> (n * 2)) & 3;
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
      sx = (reg(base) & 0x7ff) << 8 | reg(base + 2) >> 8;
      sy = (reg(base + 4) & 0x7ff) << 8 | reg(base + 6) >> 8;
      dx = (reg(base + 8) & 7) << 8 | reg(base + 10) >> 8;
      int dy = (reg(base + 12) & 7) << 8 | reg(base + 14) >> 8;
      // zoom registers are 0 after reset: treat as 1.0
      if (dx == 0) dx = 0x100;
      if (dy == 0) dy = 0x100;
      sy += y * dy;

      // line scroll
      final scrctl = reg(0x9a) >> (n * 8);
      if (scrctl & 0x0e != 0) {
        final interval = 1 << ((scrctl >> 4) & 3);
        final tableAddr =
            ((reg(0xa0 + n * 4) & 7) << 16 | reg(0xa2 + n * 4) & 0xfffe) << 1;
        final entrySize = (scrctl.bit1 ? 4 : 0) +
            (scrctl.bit2 ? 4 : 0) +
            (scrctl.bit3 ? 4 : 0);
        int addr = tableAddr + (y ~/ interval) * entrySize;
        if (scrctl.bit1) {
          sx += (vramData.getUint32(addr & 0x7fffc) >> 8) & 0x7ffff;
          addr += 4;
        }
        if (scrctl.bit2) {
          sy = (reg(base + 4) & 0x7ff) << 8 | reg(base + 6) >> 8;
          sy += (vramData.getUint32(addr & 0x7fffc) >> 8) & 0x7ffff;
          addr += 4;
        }
        if (scrctl.bit3) {
          dx = (vramData.getUint32(addr & 0x7fffc) >> 8) & 0x7ff;
        }
      }
    } else {
      final base = 0x90 + (n - 2) * 4;
      sx = (reg(base) & 0x7ff) << 8;
      sy = ((reg(base + 2) & 0x7ff) + y) << 8;
      dx = 0x100;
    }

    final py = sy >> 8;

    if (cfg.bitmap) {
      for (int x = 0; x < w; x++) {
        buf[x] = _bitmapDot(cfg, (sx + x * dx) >> 8, py);
      }
      return true;
    }

    _lastCellKey = -1;
    for (int x = 0; x < w; x++) {
      buf[x] = _cellDot(cfg, (sx + x * dx) >> 8, py);
    }
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
      charNum = w1 & 0x7fff;
      _pnHf = w0.bit14;
      _pnVf = w0.bit15;
      _pnSpr = w0.bit13;
      _pnPalette = cfg.colorMode == 0 ? w0 & 0x7f : w0 & 0x70;
    } else {
      final d = vramData.getUint16(addr & 0x7fffe);
      _pnSpr = pncn.bit9;
      _pnPalette = cfg.colorMode == 0
          ? (d >> 12) & 0xf | (pncn & 0xe0) >> 1
          : (d >> 8) & 0x70;

      if (!pncn.bit14) {
        _pnHf = d.bit10;
        _pnVf = d.bit11;
        charNum = cfg.char16
            ? (d & 0x3ff) << 2 | pncn & 0x3 | (pncn & 0x1c) << 10
            : (d & 0x3ff) | (pncn & 0x1f) << 10;
      } else {
        _pnHf = false;
        _pnVf = false;
        charNum = cfg.char16
            ? (d & 0xfff) << 2 | pncn & 0x3 | (pncn & 0x10) << 10
            : (d & 0xfff) | (pncn & 0x1c) << 10;
      }
    }

    _pnCharAddr = (charNum & 0x3fff) << 5;
  }

  static const _cellBytes = [32, 64, 128, 128, 256, 256, 256, 256];

  int _cellDot(_MapCfg cfg, int x, int y) {
    x &= cfg.mapDotsW - 1;
    y &= cfg.mapDotsH - 1;

    final key = (y >> 3) << 16 | (x >> 3);
    if (key != _lastCellKey) {
      _lastCellKey = key;
      _setupCell(cfg, x, y);
    }

    if (_cellPri == 0) {
      return 0;
    }

    final dx = _cellHf ? 7 - (x & 7) : x & 7;
    final dy = _cellVf ? 7 - (y & 7) : y & 7;
    return _dot(cfg, _cellAddr, dx, dy, 8, _cellPalette, _cellPri);
  }

  void _setupCell(_MapCfg cfg, int x, int y) {
    final planeW = cfg.planeDotsW;
    final planeH = cfg.planeDotsH;
    final plane = (y ~/ planeH) * cfg.mapW + (x ~/ planeW);
    final px = x & (planeW - 1);
    final py = y & (planeH - 1);
    final page = (py >> 9) * cfg.planeW + (px >> 9);
    final cx = px & 511;
    final cy = py & 511;

    final patternIndex =
        cfg.char16 ? (cy >> 4) * 32 + (cx >> 4) : (cy >> 3) * 64 + (cx >> 3);
    final patternAddr = cfg.planeAddr[plane] +
        page * cfg.pageBytes +
        patternIndex * cfg.pnSize;

    _decodePattern(cfg, patternAddr);

    int addr = _pnCharAddr;
    if (cfg.char16) {
      // select one of 2x2 cells, flips apply to the whole 16x16 character
      int subX = (cx >> 3) & 1;
      int subY = (cy >> 3) & 1;
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

  int _bitmapDot(_MapCfg cfg, int x, int y) {
    x &= cfg.bitmapW - 1;
    y &= cfg.bitmapH - 1;
    return _dot(cfg, cfg.bitmapAddr, x, y, cfg.bitmapW, cfg.bitmapPalette << 4,
        cfg.priority);
  }

  /// fetches a dot from character / bitmap data at (x, y), returns packed pixel
  int _dot(_MapCfg cfg, int base, int x, int y, int stride, int palette,
      int pri) {
    int color;
    switch (cfg.colorMode) {
      case 0:
        final b = vram[(base + ((y * stride + x) >> 1)) & 0x7ffff];
        final d = x.bit0 ? b & 0xf : b >> 4;
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
            vramData.getUint16((base + (y * stride + x) * 2) & 0x7fffe) & 0x7ff;
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
        color = d & 0xffffff;
        break;
    }

    return pri << 24 | (cfg.ccEnabled ? _ccBit : 0) | color;
  }

  // ---- sprite ----

  final _sprPri = Int32List(8);
  final _sprRatio = Int32List(8);

  /// renders the sprite layer, returns false when nothing can be displayed
  bool _renderSprite(int y, int w, Int32List buf) {
    final spctl = reg(0xe0);
    final type = spctl & 0xf;
    final rgbMixed = spctl.bit5;
    final ccCond = (spctl >> 12) & 3;
    final ccNum = (spctl >> 8) & 7;
    final ccEnabled = reg(0xec).bit6;
    final craOffset = ((reg(0xe6) >> 4) & 7) << 8;

    int anyPri = 0;
    for (int i = 0; i < 8; i++) {
      _sprPri[i] = (reg(0xf0 + (i >> 1) * 2) >> (i.bit0 ? 8 : 0)) & 7;
      _sprRatio[i] = (reg(0x100 + (i >> 1) * 2) >> (i.bit0 ? 8 : 0)) & 0x1f;
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
      final fx = hiRes ? x >> 1 : x;
      final d = fb[rowBase + (fx & (fbWidth - 1))];

      if (d == 0) {
        buf[x] = 0;
        continue;
      }

      if (rgbMixed && d.bit15) {
        // RGB direct color
        _spriteRatio[x] = _sprRatio[0];
        buf[x] =
            rgbPri == 0 ? 0 : rgbPri << 24 | (rgbCc ? _ccBit : 0) | _rgb555(d);
        continue;
      }

      int prIndex = 0, ccIndex = 0, dc = 0;
      switch (type) {
        case 0:
          prIndex = (d >> 14) & 3;
          ccIndex = (d >> 11) & 7;
          dc = d & 0x7ff;
          break;
        case 1:
          prIndex = (d >> 13) & 7;
          ccIndex = (d >> 11) & 3;
          dc = d & 0x7ff;
          break;
        case 2:
          prIndex = (d >> 14) & 1;
          ccIndex = (d >> 11) & 7;
          dc = d & 0x7ff;
          break;
        case 3:
          prIndex = (d >> 13) & 3;
          ccIndex = (d >> 11) & 3;
          dc = d & 0x7ff;
          break;
        case 4:
          prIndex = (d >> 13) & 3;
          ccIndex = (d >> 10) & 7;
          dc = d & 0x3ff;
          break;
        case 5:
          prIndex = (d >> 12) & 7;
          ccIndex = (d >> 11) & 1;
          dc = d & 0x7ff;
          break;
        case 6:
          prIndex = (d >> 12) & 7;
          ccIndex = (d >> 10) & 3;
          dc = d & 0x3ff;
          break;
        case 7:
          prIndex = (d >> 12) & 7;
          ccIndex = (d >> 9) & 7;
          dc = d & 0x1ff;
          break;
        case 8:
          prIndex = (d >> 7) & 1;
          dc = d & 0x7f;
          break;
        case 9:
          prIndex = (d >> 7) & 1;
          ccIndex = (d >> 6) & 1;
          dc = d & 0x3f;
          break;
        case 10:
          prIndex = (d >> 6) & 3;
          dc = d & 0x3f;
          break;
        case 11:
          ccIndex = (d >> 6) & 3;
          dc = d & 0x3f;
          break;
        case 12:
          prIndex = (d >> 7) & 1;
          dc = d & 0xff;
          break;
        case 13:
          prIndex = (d >> 7) & 1;
          ccIndex = (d >> 6) & 1;
          dc = d & 0xff;
          break;
        case 14:
          prIndex = (d >> 6) & 3;
          dc = d & 0xff;
          break;
        default:
          ccIndex = (d >> 6) & 3;
          dc = d & 0xff;
          break;
      }

      if (type >= 8 && d & 0xff == 0) {
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
      buf[x] = pri << 24 | (cc ? _ccBit : 0) | _color(craOffset + dc);
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
    int addr = ((bktau & 7) << 16 | reg(0xae)) << 1;
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
      _ratios[l] = (reg(_layerRatioRegs[l]) >> _layerRatioShift[l]) & 0x1f;
    }
  }

  int _offset(int l, int c) {
    if (!_offOn[l]) return c;
    int r = (c & 0xff) + _offR[l];
    int g = ((c >> 8) & 0xff) + _offG[l];
    int b = ((c >> 16) & 0xff) + _offB[l];
    r = r < 0 ? 0 : (r > 255 ? 255 : r);
    g = g < 0 ? 0 : (g > 255 ? 255 : g);
    b = b < 0 ? 0 : (b > 255 ? 255 : b);
    return b << 16 | g << 8 | r;
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

    final lines = _lines;
    final active = _active;

    for (int x = 0; x < w; x++) {
      int top = -1, topPri = 0, topPixel = 0;
      int second = -1, secondPri = 0, secondPixel = 0;

      for (int i = 0; i < n; i++) {
        final l = active[i];
        final p = lines[l][x];
        if (p == 0) continue;
        final pri = (p >> 24) & 7;
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
        color = _offset(top, topPixel & 0xffffff);

        if (topPixel & _ccBit != 0) {
          final under =
              second < 0 ? back : _offset(second, secondPixel & 0xffffff);
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
    int r = (a & 0xff) + (b & 0xff);
    int g = ((a >> 8) & 0xff) + ((b >> 8) & 0xff);
    int bl = ((a >> 16) & 0xff) + ((b >> 16) & 0xff);
    if (r > 255) r = 255;
    if (g > 255) g = 255;
    if (bl > 255) bl = 255;
    return bl << 16 | g << 8 | r;
  }

  // ratio 0: top only, 31: almost bottom only
  static int _blend(int a, int b, int ratio) {
    final ta = 32 - ratio;
    final tb = ratio;
    final r = ((a & 0xff) * ta + (b & 0xff) * tb) >> 5;
    final g = (((a >> 8) & 0xff) * ta + ((b >> 8) & 0xff) * tb) >> 5;
    final bl = (((a >> 16) & 0xff) * ta + ((b >> 16) & 0xff) * tb) >> 5;
    return bl << 16 | g << 8 | r;
  }

  String dump() {
    final r = List.generate(
        8, (i) => regs.sublist(i * 16, i * 16 + 16).map((e) => e.x4).join(" "));
    return "vdp2: line:$line ${width}x$height\n${r.join("\n")}";
  }
}
