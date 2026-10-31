import 'dart:typed_data';

import '../../types.dart';
import '../../util/int.dart';
import 'bus.dart';

/// scanline based picture processor
class Ppu {
  static const width = 160;
  static const height = 144;
  static const clocksInLine = 456;
  static const linesInFrame = 154;

  static const _mode2Clocks = 80;
  static const _mode3Clocks = 172;

  // RGBA (little endian) of the 4 shades
  static const colors = [0xffd0f8e0, 0xff70c088, 0xff566834, 0xff201808];

  static const vramBankSize = 0x2000;

  final Bus _bus;

  // GBC has two VRAM banks. Bank 1 holds the BG map attributes at the map addresses.
  final vram = Uint8List(vramBankSize * 2);
  final oam = Uint8List(0xa0);

  int lcdc = 0x91;
  int stat = 0;
  int scy = 0, scx = 0;
  int ly = 0, lyc = 0;
  int bgp = 0xfc, obp0 = 0xff, obp1 = 0xff;
  int wy = 0, wx = 0;

  // GBC registers: VBK, BCPS/OCPS, OPRI
  int vramBank = 0;
  int _bcps = 0, _ocps = 0;
  int _opri = 0;

  // GBC palette RAM: 8 palettes of 4 colors, little endian RGB555
  final _bgPalette = Uint8List(64);
  final _objPalette = Uint8List(64);
  // the same palettes converted to RGBA for rendering
  final _bgColors = Uint32List(32);
  final _objColors = Uint32List(32);

  int mode = 0;
  int _dot = 0;
  int _windowLine = 0;
  bool _windowTriggered = false;
  bool _statLine = false;

  // double buffered screen
  var _back = Uint32List(width * height);
  var _front = Uint32List(width * height);

  /// frames completed. incremented on the vertical blank
  int frames = 0;

  final _bgIndex = Uint8List(width); // bg/window color index for priority
  final _bgAttr = Uint8List(width); // bg/window map attributes (GBC)
  final _spriteOwned = Uint8List(width);

  Ppu(this._bus);

  bool get lcdOn => lcdc.bit7;

  bool get _gbc => _bus.gbc;

  void reset() {
    lcdc = 0x91;
    stat = 0;
    scy = scx = 0;
    ly = lyc = 0;
    bgp = 0xfc;
    obp0 = obp1 = 0xff;
    wy = wx = 0;
    vramBank = 0;
    _bcps = _ocps = 0;
    _opri = 0;
    _bgPalette.fillRange(0, _bgPalette.length, 0xff);
    _objPalette.fillRange(0, _objPalette.length, 0xff);
    _convertPalette(_bgPalette, _bgColors);
    _convertPalette(_objPalette, _objColors);
    mode = 2;
    _dot = 0;
    _windowLine = 0;
    _windowTriggered = false;
    _statLine = false;
    frames = 0;
    vram.fillRange(0, vram.length, 0);
    oam.fillRange(0, oam.length, 0);
    _back.fillRange(0, _back.length, colors[0]);
    _front.fillRange(0, _front.length, colors[0]);
  }

  ImageBuffer get imageBuffer => ImageBuffer(width, height, _front,
      displayWidth_: 269); // keep 10:9 aspect ratio at 242 lines

  void _updateStat() {
    final coincidence = ly == lyc;
    final line = (coincidence && stat.bit6) ||
        (mode == 0 && stat.bit3) ||
        (mode == 1 && stat.bit4) ||
        (mode == 2 && stat.bit5);

    if (line && !_statLine) {
      _bus.requestInterrupt(Bus.intStat);
    }
    _statLine = line;
  }

  /// advances by system clocks (dots): 4 per machine cycle, 2 in GBC double speed
  void tick(int dots) {
    if (!lcdOn) {
      return;
    }

    _dot += dots;

    if (ly < height) {
      if (mode == 2 && _dot >= _mode2Clocks) {
        mode = 3;
        _updateStat();
      } else if (mode == 3 && _dot >= _mode2Clocks + _mode3Clocks) {
        _renderLine();
        mode = 0;
        _updateStat();
        _bus.hblank();
      }
    }

    if (_dot >= clocksInLine) {
      _dot -= clocksInLine;
      ly++;

      if (ly == height) {
        mode = 1;
        _bus.requestInterrupt(Bus.intVBlank);
        _swapBuffers();
      } else if (ly == linesInFrame) {
        ly = 0;
        _windowLine = 0;
        _windowTriggered = false;
        mode = 2;
      } else if (ly < height) {
        mode = 2;
      }

      _updateStat();
    }
  }

  void _swapBuffers() {
    final t = _front;
    _front = _back;
    _back = t;
    frames++;
  }

  int read(int addr) => switch (addr) {
        0xff40 => lcdc,
        0xff41 => 0x80 | stat & 0x78 | (ly == lyc ? 4 : 0) | mode,
        0xff42 => scy,
        0xff43 => scx,
        0xff44 => ly,
        0xff45 => lyc,
        0xff46 => 0xff,
        0xff47 => bgp,
        0xff48 => obp0,
        0xff49 => obp1,
        0xff4a => wy,
        0xff4b => wx,
        0xff4f => _gbc ? 0xfe | vramBank : 0xff,
        0xff68 => _gbc ? _bcps | 0x40 : 0xff,
        0xff69 => _gbc ? _bgPalette[_bcps & 0x3f] : 0xff,
        0xff6a => _gbc ? _ocps | 0x40 : 0xff,
        0xff6b => _gbc ? _objPalette[_ocps & 0x3f] : 0xff,
        0xff6c => _gbc ? 0xfe | _opri : 0xff,
        _ => 0xff,
      };

  void write(int addr, int data) {
    switch (addr) {
      case 0xff4f:
        if (_gbc) {
          vramBank = data & 1;
        }
      case 0xff68:
        if (_gbc) {
          _bcps = data & 0xbf;
        }
      case 0xff69:
        if (_gbc) {
          _writePalette(_bgPalette, _bgColors, _bcps & 0x3f, data);
          _bcps = _nextPaletteIndex(_bcps);
        }
      case 0xff6a:
        if (_gbc) {
          _ocps = data & 0xbf;
        }
      case 0xff6b:
        if (_gbc) {
          _writePalette(_objPalette, _objColors, _ocps & 0x3f, data);
          _ocps = _nextPaletteIndex(_ocps);
        }
      case 0xff6c:
        if (_gbc) {
          _opri = data & 1;
        }
      case 0xff40:
        final wasOn = lcdOn;
        lcdc = data;
        if (wasOn && !lcdOn) {
          ly = 0;
          _dot = 0;
          mode = 0;
          _windowLine = 0;
          _windowTriggered = false;
          _statLine = false;
          _front.fillRange(0, _front.length, colors[0]);
        } else if (!wasOn && lcdOn) {
          ly = 0;
          _dot = 0;
          mode = 2;
          _updateStat();
        }
      case 0xff41:
        stat = data & 0x78;
        if (lcdOn) {
          _updateStat();
        }
      case 0xff42:
        scy = data;
      case 0xff43:
        scx = data;
      case 0xff45:
        lyc = data;
        if (lcdOn) {
          _updateStat();
        }
      case 0xff47:
        bgp = data;
      case 0xff48:
        obp0 = data;
      case 0xff49:
        obp1 = data;
      case 0xff4a:
        wy = data;
      case 0xff4b:
        wx = data;
    }
  }

  // GBC palette RAM: BCPS/OCPS bit 7 increments the index after each data write
  static int _nextPaletteIndex(int spec) =>
      spec.bit7 ? 0x80 | ((spec + 1) & 0x3f) : spec;

  void _writePalette(Uint8List ram, Uint32List colors, int index, int data) {
    ram[index] = data;
    final n = index >> 1;
    colors[n] = _rgba(ram[n * 2], ram[n * 2 + 1]);
  }

  static void _convertPalette(Uint8List ram, Uint32List colors) {
    for (int n = 0; n < colors.length; n++) {
      colors[n] = _rgba(ram[n * 2], ram[n * 2 + 1]);
    }
  }

  // RGB555 (little endian) to RGBA, expanding each 5bit channel to 8bit
  static int _rgba(int lo, int hi) {
    final v = lo | hi << 8;
    int channel(int shift) {
      final c = (v >> shift) & 31;
      return c << 3 | c >> 2;
    }

    return 0xff000000 | channel(10) << 16 | channel(5) << 8 | channel(0);
  }

  // returns 2bit color index of the pixel in the tile
  @pragma('vm:prefer-inline')
  int _tilePixel(int tileAddr, int row, int col) {
    final lo = vram[tileAddr + row * 2];
    final hi = vram[tileAddr + row * 2 + 1];
    final bit = 7 - col;
    return (lo >> bit).mask1 | (hi >> bit).mask1.shl1;
  }

  // vram offset of the bg/window tile data
  @pragma('vm:prefer-inline')
  int _bgTileAddr(int tileNo) =>
      lcdc.bit4 ? tileNo * 16 : 0x1000 + tileNo.rel8 * 16;

  void _renderLine() {
    final base = ly * width;

    if (ly == wy) {
      _windowTriggered = true;
    }

    // GBC keeps drawing the BG when LCDC bit 0 is clear; it only drops BG priority
    if (lcdc.bit0 || _gbc) {
      // background
      final mapBase = lcdc.bit3 ? 0x1c00 : 0x1800;
      final y = (scy + ly).mask8;
      final rowBase = mapBase + y.shr3 * 32;
      final fineY = y.mask3;

      for (int x = 0; x < width; x++) {
        final sx = (scx + x).mask8;
        _setBgPixel(x, rowBase + sx.shr3, fineY, sx.mask3);
      }

      // window
      if (lcdc.bit5 && _windowTriggered && wx <= 166) {
        final winMap = lcdc.bit6 ? 0x1c00 : 0x1800;
        final winRow = winMap + _windowLine.shr3 * 32;
        final winFineY = _windowLine.mask3;
        final startX = wx - 7;

        for (int x = startX < 0 ? 0 : startX; x < width; x++) {
          final wxp = x - startX;
          _setBgPixel(x, winRow + wxp.shr3, winFineY, wxp.mask3);
        }
        _windowLine++;
      }

      for (int x = 0; x < width; x++) {
        _back[base + x] = _gbc
            ? _bgColors[(_bgAttr[x] & 7) * 4 + _bgIndex[x]]
            : colors[(bgp >> (_bgIndex[x] * 2)).mask2];
      }
    } else {
      for (int x = 0; x < width; x++) {
        _bgIndex[x] = 0;
        _bgAttr[x] = 0;
        _back[base + x] = colors[0];
      }
    }

    if (lcdc.bit1) {
      _renderSprites(base);
    }
  }

  // stores the color index and map attributes of a bg/window pixel
  @pragma('vm:prefer-inline')
  void _setBgPixel(int x, int mapIndex, int row, int col) {
    final attr = _gbc ? vram[vramBankSize + mapIndex] : 0;
    final tileAddr =
        _bgTileAddr(vram[mapIndex]) + (attr.bit3 ? vramBankSize : 0);
    _bgIndex[x] = _tilePixel(
        tileAddr, attr.bit6 ? 7 - row : row, attr.bit5 ? 7 - col : col);
    _bgAttr[x] = attr;
  }

  final _lineSprites = List<int>.filled(10, 0);

  void _renderSprites(int base) {
    final spriteHeight = lcdc.bit2 ? 16 : 8;

    // OAM scan: up to 10 sprites in OAM order
    var count = 0;
    for (int i = 0; i < 40 && count < 10; i++) {
      final y = oam[i * 4] - 16;
      if (ly >= y && ly < y + spriteHeight) {
        _lineSprites[count++] = i;
      }
    }

    if (count == 0) {
      return;
    }

    // DMG priority: smaller x first, then smaller OAM index (stable insertion sort).
    // GBC uses OAM order unless OPRI selects the DMG order.
    final sortByX = !_gbc || _opri != 0;
    for (int i = 1; sortByX && i < count; i++) {
      final s = _lineSprites[i];
      final sx = oam[s * 4 + 1];
      var j = i - 1;
      while (j >= 0 && oam[_lineSprites[j] * 4 + 1] > sx) {
        _lineSprites[j + 1] = _lineSprites[j];
        j--;
      }
      _lineSprites[j + 1] = s;
    }

    _spriteOwned.fillRange(0, width, 0);

    for (int n = 0; n < count; n++) {
      final s = _lineSprites[n] * 4;
      final y = oam[s] - 16;
      final x = oam[s + 1] - 8;
      var tile = oam[s + 2];
      final attr = oam[s + 3];

      var row = ly - y;
      if (attr.bit6) {
        row = spriteHeight - 1 - row;
      }
      if (spriteHeight == 16) {
        tile = (tile & 0xfe) + row.shr3;
        row &= 7;
      }

      // GBC: palette index from bits 0-2 and tile bank from bit 3
      final palette = _gbc ? attr & 7 : (attr.bit4 ? obp1 : obp0);
      final bank = _gbc && attr.bit3 ? vramBankSize : 0;
      final behindBg = attr.bit7;
      final xFlip = attr.bit5;

      for (int col = 0; col < 8; col++) {
        final px = x + col;
        if (px < 0 || px >= width || _spriteOwned[px] != 0) {
          continue;
        }

        final color = _tilePixel(tile * 16 + bank, row, xFlip ? 7 - col : col);
        if (color == 0) {
          continue;
        }

        _spriteOwned[px] = 1;

        // BG wins over the sprite on a non-zero BG pixel. The GBC BG attribute
        // can also set this priority. LCDC bit 0 clear makes sprites always win.
        final bgWins = lcdc.bit0 &&
            _bgIndex[px] != 0 &&
            (behindBg || _gbc && _bgAttr[px].bit7);
        if (bgWins) {
          continue;
        }

        _back[base + px] = _gbc
            ? _objColors[palette * 4 + color]
            : colors[(palette >> (color * 2)).mask2];
      }
    }
  }

  // debug

  String dump() => "lcdc:${lcdc.x2} stat:${read(0xff41).x2} ly:${ly.d3} "
      "lyc:${lyc.x2} scy:${scy.x2} scx:${scx.x2} wy:${wy.x2} wx:${wx.x2} "
      "bgp:${bgp.x2} obp0:${obp0.x2} obp1:${obp1.x2} dot:${_dot.d3}";

  /// renders the whole 256x256 background map
  ImageBuffer renderBg() {
    const size = 256;
    final buf = Uint32List(size * size);
    final mapBase = lcdc.bit3 ? 0x1c00 : 0x1800;

    for (int y = 0; y < size; y++) {
      for (int x = 0; x < size; x++) {
        final tileAddr = _bgTileAddr(vram[mapBase + y.shr3 * 32 + x.shr3]);
        buf[y * size + x] =
            colors[(bgp >> (_tilePixel(tileAddr, y.mask3, x.mask3) * 2)).mask2];
      }
    }

    return ImageBuffer(size, size, buf);
  }

  int _palette(int paletteNo) => switch (paletteNo % 4) {
        0 => bgp,
        1 => obp0,
        2 => obp1,
        _ => 0xe4, // raw indexes
      };

  /// renders 384 tiles in 16 x 24 tiles
  ImageBuffer renderVram(int paletteNo) {
    const w = 128, h = 192;
    final buf = Uint32List(w * h);
    final palette = _palette(paletteNo);

    for (int t = 0; t < 384; t++) {
      final tx = (t % 16) * 8;
      final ty = (t ~/ 16) * 8;
      for (int row = 0; row < 8; row++) {
        for (int col = 0; col < 8; col++) {
          buf[(ty + row) * w + tx + col] =
              colors[(palette >> (_tilePixel(t * 16, row, col) * 2)).mask2];
        }
      }
    }

    return ImageBuffer(w, h, buf);
  }

  /// renders bg, obj0, obj1 palettes as 4 x 3 blocks of 16x16 pixels
  ImageBuffer renderColorTable() {
    const block = 16, w = block * 4, h = block * 3;
    final buf = Uint32List(w * h);
    final palettes = [bgp, obp0, obp1];

    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        buf[y * w + x] =
            colors[(palettes[y ~/ block] >> (x ~/ block * 2)).mask2];
      }
    }

    return ImageBuffer(w, h, buf);
  }

  List<String> spriteInfo() => List.generate(40, (i) {
        final s = i * 4;
        return "${i.d2} x:${oam[s + 1].d3} y:${oam[s].d3} "
            "t:${oam[s + 2].x2} a:${oam[s + 3].x2}";
      });
}
