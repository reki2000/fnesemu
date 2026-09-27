import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';

import '../types.dart';
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

  final Bus _bus;

  final vram = Uint8List(0x2000);
  final oam = Uint8List(0xa0);

  int lcdc = 0x91;
  int stat = 0;
  int scy = 0, scx = 0;
  int ly = 0, lyc = 0;
  int bgp = 0xfc, obp0 = 0xff, obp1 = 0xff;
  int wy = 0, wx = 0;

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
  final _spriteOwned = Uint8List(width);

  Ppu(this._bus);

  bool get lcdOn => lcdc & 0x80 != 0;

  void reset() {
    lcdc = 0x91;
    stat = 0;
    scy = scx = 0;
    ly = lyc = 0;
    bgp = 0xfc;
    obp0 = obp1 = 0xff;
    wy = wx = 0;
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

  ImageBuffer get imageBuffer => ImageBuffer(
      width, height, _front.buffer.asUint8List(),
      displayWidth_: 269); // keep 10:9 aspect ratio at 242 lines

  void _updateStat() {
    final coincidence = ly == lyc;
    final line = (coincidence && stat & 0x40 != 0) ||
        (mode == 0 && stat & 0x08 != 0) ||
        (mode == 1 && stat & 0x10 != 0) ||
        (mode == 2 && stat & 0x20 != 0);

    if (line && !_statLine) {
      _bus.requestInterrupt(Bus.intStat);
    }
    _statLine = line;
  }

  /// one machine cycle
  void tick() {
    if (!lcdOn) {
      return;
    }

    _dot += 4;

    if (ly < height) {
      if (mode == 2 && _dot >= _mode2Clocks) {
        mode = 3;
        _updateStat();
      } else if (mode == 3 && _dot >= _mode2Clocks + _mode3Clocks) {
        _renderLine();
        mode = 0;
        _updateStat();
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
        _ => 0xff,
      };

  void write(int addr, int data) {
    switch (addr) {
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

  // returns 2bit color index of the pixel in the tile
  @pragma('vm:prefer-inline')
  int _tilePixel(int tileAddr, int row, int col) {
    final lo = vram[tileAddr + row * 2];
    final hi = vram[tileAddr + row * 2 + 1];
    final bit = 7 - col;
    return (lo >> bit & 1) | (hi >> bit & 1) << 1;
  }

  // vram offset of the bg/window tile data
  @pragma('vm:prefer-inline')
  int _bgTileAddr(int tileNo) =>
      lcdc & 0x10 != 0 ? tileNo * 16 : 0x1000 + tileNo.rel8 * 16;

  void _renderLine() {
    final base = ly * width;

    if (ly == wy) {
      _windowTriggered = true;
    }

    if (lcdc & 0x01 != 0) {
      // background
      final mapBase = lcdc & 0x08 != 0 ? 0x1c00 : 0x1800;
      final y = (scy + ly) & 0xff;
      final rowBase = mapBase + (y >> 3) * 32;
      final fineY = y & 7;

      for (int x = 0; x < width; x++) {
        final sx = (scx + x) & 0xff;
        final tileAddr = _bgTileAddr(vram[rowBase + (sx >> 3)]);
        _bgIndex[x] = _tilePixel(tileAddr, fineY, sx & 7);
      }

      // window
      if (lcdc & 0x20 != 0 && _windowTriggered && wx <= 166) {
        final winMap = lcdc & 0x40 != 0 ? 0x1c00 : 0x1800;
        final winRow = winMap + (_windowLine >> 3) * 32;
        final winFineY = _windowLine & 7;
        final startX = wx - 7;

        for (int x = startX < 0 ? 0 : startX; x < width; x++) {
          final wxp = x - startX;
          final tileAddr = _bgTileAddr(vram[winRow + (wxp >> 3)]);
          _bgIndex[x] = _tilePixel(tileAddr, winFineY, wxp & 7);
        }
        _windowLine++;
      }

      for (int x = 0; x < width; x++) {
        _back[base + x] = colors[bgp >> (_bgIndex[x] * 2) & 3];
      }
    } else {
      for (int x = 0; x < width; x++) {
        _bgIndex[x] = 0;
        _back[base + x] = colors[0];
      }
    }

    if (lcdc & 0x02 != 0) {
      _renderSprites(base);
    }
  }

  final _lineSprites = List<int>.filled(10, 0);

  void _renderSprites(int base) {
    final spriteHeight = lcdc & 0x04 != 0 ? 16 : 8;

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

    // priority: smaller x first, then smaller OAM index (stable insertion sort)
    for (int i = 1; i < count; i++) {
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
      if (attr & 0x40 != 0) {
        row = spriteHeight - 1 - row;
      }
      if (spriteHeight == 16) {
        tile = (tile & 0xfe) + (row >> 3);
        row &= 7;
      }

      final palette = attr & 0x10 != 0 ? obp1 : obp0;
      final behindBg = attr & 0x80 != 0;
      final xFlip = attr & 0x20 != 0;

      for (int col = 0; col < 8; col++) {
        final px = x + col;
        if (px < 0 || px >= width || _spriteOwned[px] != 0) {
          continue;
        }

        final color = _tilePixel(tile * 16, row, xFlip ? 7 - col : col);
        if (color == 0) {
          continue;
        }

        _spriteOwned[px] = 1;

        if (behindBg && _bgIndex[px] != 0) {
          continue;
        }

        _back[base + px] = colors[palette >> (color * 2) & 3];
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
    final mapBase = lcdc & 0x08 != 0 ? 0x1c00 : 0x1800;

    for (int y = 0; y < size; y++) {
      for (int x = 0; x < size; x++) {
        final tileAddr = _bgTileAddr(vram[mapBase + (y >> 3) * 32 + (x >> 3)]);
        buf[y * size + x] =
            colors[bgp >> (_tilePixel(tileAddr, y & 7, x & 7) * 2) & 3];
      }
    }

    return ImageBuffer(size, size, buf.buffer.asUint8List());
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
              colors[palette >> (_tilePixel(t * 16, row, col) * 2) & 3];
        }
      }
    }

    return ImageBuffer(w, h, buf.buffer.asUint8List());
  }

  /// renders bg, obj0, obj1 palettes as 4 x 3 blocks of 16x16 pixels
  ImageBuffer renderColorTable() {
    const block = 16, w = block * 4, h = block * 3;
    final buf = Uint32List(w * h);
    final palettes = [bgp, obp0, obp1];

    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        buf[y * w + x] = colors[palettes[y ~/ block] >> (x ~/ block * 2) & 3];
      }
    }

    return ImageBuffer(w, h, buf.buffer.asUint8List());
  }

  List<String> spriteInfo() => List.generate(40, (i) {
        final s = i * 4;
        return "${i.d2} x:${oam[s + 1].d3} y:${oam[s].d3} "
            "t:${oam[s + 2].x2} a:${oam[s + 3].x2}";
      });
}
