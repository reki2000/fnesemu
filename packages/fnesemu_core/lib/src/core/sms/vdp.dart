import 'dart:math';
import 'dart:typed_data';

import '../../types.dart';
import '../../util/int.dart';

/// The video display processor of the sms core: the TMS9918 modes, the mode
/// 4 and the portable console's 12-bit colors. Renders one scanline at a
/// time into a 256 pixel wide buffer.
class Vdp {
  /// the TMS9918A has no mode 4 and no line interrupt
  final bool tms;

  /// the portable console has 12-bit colors and shows a 160x144 window
  final bool gg;

  Vdp({this.tms = false, this.gg = false});

  /// the portable console runs a cartridge of the mode 4 console: 6-bit
  /// colors, and the whole picture is scaled into the window
  bool compatible = false;

  bool get _colors12 => gg && !compatible;

  static const width = 256;
  static const linesInFrame = 262;
  static const ggWidth = 160, ggHeight = 144;

  final vram = Uint8List(0x4000);
  final cram = Uint8List(64);
  final reg = Uint8List(16);

  int _addr = 0;
  int _code = 0;
  bool _latched = false;
  int _readBuffer = 0;
  int _cramLatch = 0;

  // status flags
  bool _frameInt = false;
  bool _overflow = false;
  bool _collision = false;
  int _fifthSprite = 0;
  bool _lineInt = false;

  int _lineCounter = 0;
  int _vscroll = 0;

  /// the current scanline
  int line = 0;

  /// frames completed. incremented when the active display ends
  int frames = 0;

  // RGBA colors of the CRAM entries
  final _palette = Uint32List(32);

  // pixels in the line being rendered: bg color index + priority, sprite index
  final _bgLine = Uint8List(width);
  final _spriteLine = Uint8List(width);
  final _spriteHit = Uint8List(width);

  var _back = Uint32List(width * 240);
  var _front = Uint32List(width * 240);
  int _frontHeight = 192;

  void reset() {
    vram.fillRange(0, vram.length, 0);
    cram.fillRange(0, cram.length, 0);
    reg.fillRange(0, reg.length, 0);
    // the values left by the boot ROM
    if (!tms) {
      reg.setAll(0, [0x36, 0x80, 0xff, 0xff, 0xff, 0xff, 0xfb, 0x00]);
      reg[10] = 0xff;
    }
    _addr = _code = _readBuffer = _cramLatch = 0;
    _latched = false;
    _frameInt = _overflow = _collision = _lineInt = false;
    _fifthSprite = 0;
    _lineCounter = 0xff;
    _vscroll = 0;
    line = 0;
    frames = 0;
    for (var i = 0; i < 32; i++) {
      _updatePalette(i);
    }
    _back.fillRange(0, _back.length, 0xff000000);
    _front.fillRange(0, _front.length, 0xff000000);
  }

  bool get mode4 => !tms && reg[0].bit2;
  bool get displayOn => reg[1].bit6;

  /// the number of active lines: 192, or 224 in the extended mode 4
  int get activeLines => mode4 && reg[0].bit1 && reg[1].bit4 ? 224 : 192;

  /// the interrupt request line to the CPU
  bool get irq => _frameInt && reg[1].bit5 || _lineInt && reg[0].bit4;

  // ----------------------------------------------------------------------
  // ports

  void writeControl(int data) {
    if (!_latched) {
      _addr = _addr & 0x3f00 | data;
      _latched = true;
      return;
    }
    _latched = false;
    _addr = data.mask6.shl8 | _addr.mask8;
    _code = data.shr6;
    switch (_code) {
      case 0: // vram read: prefetches the read buffer
        _readBuffer = vram[_addr];
        _addr = _addr.inc.mask14;
      case 2: // register write
        final no = tms ? data.mask3 : data.mask4;
        if (no < 11) reg[no] = _addr.mask8;
    }
  }

  void writeData(int data) {
    _latched = false;
    if (_code == 3 && !tms) {
      if (_colors12) {
        if (!_addr.bit0) {
          _cramLatch = data;
        } else {
          cram[_addr.mask6 & 0x3e] = _cramLatch;
          cram[_addr.mask6] = data;
          _updatePalette(_addr.mask6.shr1);
        }
      } else {
        cram[_addr.mask5] = data;
        _updatePalette(_addr.mask5);
      }
    } else {
      vram[_addr] = data;
    }
    _readBuffer = data;
    _addr = _addr.inc.mask14;
  }

  int readData() {
    _latched = false;
    final value = _readBuffer;
    _readBuffer = vram[_addr];
    _addr = _addr.inc.mask14;
    return value;
  }

  int readStatus() {
    _latched = false;
    final value = (_frameInt ? 0x80 : 0) |
        (_overflow ? 0x40 : 0) |
        (_collision ? 0x20 : 0) |
        (tms ? _fifthSprite : 0x1f);
    _frameInt = _overflow = _collision = _lineInt = false;
    return value;
  }

  int get vCounter {
    if (activeLines == 224) return line <= 0xea ? line : line - 6;
    return line <= 0xda ? line : line - 6;
  }

  /// the horizontal counter at [cycles] CPU cycles into the line
  ///
  /// a line starts when the counter is 0xf4, counts up to 0x93 and jumps to
  /// 0xe9: 171 values in 228 cycles
  static int hCounter(int cycles) {
    final index = ((cycles % 228) * 3 + 2) ~/ 4;
    if (index < 12) return 0xf4 + index;
    if (index < 160) return index - 12;
    return 0xe9 + index - 160;
  }

  // the horizontal counter latched by the TH pins
  int hLatch = 0;

  // ----------------------------------------------------------------------
  // scanline processing

  /// processes the current line and advances to the next one
  void runLine() {
    final active = activeLines;
    if (line == 0) {
      _vscroll = reg[9];
    }

    if (line < active) {
      _renderLine(line);
    } else if (mode4 && displayOn) {
      // sprites in the borders still collide
      _renderSprites4(vCounter);
    }
    if (line == active) {
      _swap(active);
      frames++;
    }

    line++;
    if (line == linesInFrame) {
      line = 0;
    }

    // the events at the start of the new line, just before the counter
    // changes: the line counter runs on the active lines and the line after
    // them, and the frame interrupt comes on the second line after them
    if (line <= active) {
      _lineCounter--;
      if (_lineCounter < 0) {
        _lineCounter = reg[10];
        if (!tms) _lineInt = true;
      }
    } else {
      _lineCounter = reg[10];
    }
    if (line == active + 1) _frameInt = true;
    _evaluateSprites4(vCounter);
  }

  void _swap(int height) {
    final tmp = _back;
    _back = _front;
    _front = tmp;
    _frontHeight = height;
  }

  ImageBuffer get imageBuffer {
    if (gg && compatible) return _scaledImage();
    if (gg) {
      final top = (_frontHeight - ggHeight) ~/ 2;
      final buf = Uint32List(ggWidth * ggHeight);
      for (var y = 0; y < ggHeight; y++) {
        final src = (top + y) * width + (width - ggWidth) ~/ 2;
        buf.setRange(y * ggWidth, (y + 1) * ggWidth, _front, src);
      }
      return ImageBuffer(ggWidth, ggHeight, buf);
    }
    return ImageBuffer(width, _frontHeight,
        Uint32List.sublistView(_front, 0, width * _frontHeight),
        displayWidth_: width * 8 ~/ 7);
  }

  /// scales the picture into the window by averaging the source pixels
  /// which each window pixel covers
  ImageBuffer _scaledImage() {
    final buf = Uint32List(ggWidth * ggHeight);
    final h = _frontHeight;
    for (var y = 0; y < ggHeight; y++) {
      final y0 = y * h ~/ ggHeight;
      final y1 = max(y0 + 1, (y + 1) * h ~/ ggHeight);
      for (var x = 0; x < ggWidth; x++) {
        final x0 = x * width ~/ ggWidth;
        final x1 = max(x0 + 1, (x + 1) * width ~/ ggWidth);
        var r = 0, g = 0, b = 0;
        for (var sy = y0; sy < y1; sy++) {
          for (var sx = x0; sx < x1; sx++) {
            final c = _front[sy * width + sx];
            r += c & 0xff;
            g += c >> 8 & 0xff;
            b += c >> 16 & 0xff;
          }
        }
        final n = (y1 - y0) * (x1 - x0);
        buf[y * ggWidth + x] = _rgba(r ~/ n, g ~/ n, b ~/ n);
      }
    }
    return ImageBuffer(ggWidth, ggHeight, buf);
  }

  // ----------------------------------------------------------------------
  // colors

  static int _rgba(int r, int g, int b) => 0xff000000 | b.shl16 | g.shl8 | r;

  void _updatePalette(int index) {
    if (_colors12) {
      final value = cram[index * 2] | cram[index * 2 + 1].shl8;
      _palette[index] =
          _rgba(value.mask4 * 17, value.shr4.mask4 * 17, value.shr8.mask4 * 17);
    } else {
      final value = cram[index];
      _palette[index] =
          _rgba(value.mask2 * 85, value.shr2.mask2 * 85, value.shr4.mask2 * 85);
    }
  }

  /// the fixed palette of the TMS9918A
  static final tmsPalette = Uint32List.fromList([
    _rgba(0, 0, 0),
    _rgba(0, 0, 0),
    _rgba(33, 200, 66),
    _rgba(94, 220, 120),
    _rgba(84, 85, 237),
    _rgba(125, 118, 252),
    _rgba(212, 82, 77),
    _rgba(66, 235, 245),
    _rgba(252, 85, 84),
    _rgba(255, 121, 120),
    _rgba(212, 193, 84),
    _rgba(230, 206, 128),
    _rgba(33, 176, 59),
    _rgba(201, 91, 186),
    _rgba(204, 204, 204),
    _rgba(255, 255, 255),
  ]);

  // ----------------------------------------------------------------------
  // rendering

  void _renderLine(int y) {
    final out = y * width;
    if (mode4) {
      final backdrop = _palette[16 + reg[7].mask4];
      if (!displayOn) {
        _back.fillRange(out, out + width, backdrop);
        return;
      }
      _renderBg4(y);
      _renderSprites4(y);
      for (var x = 0; x < width; x++) {
        final sprite = _spriteLine[x];
        final bg = _bgLine[x];
        final color = sprite != 0 && (bg & 0x20 == 0 || bg & 0x0f == 0)
            ? sprite
            : bg & 0x1f;
        _back[out + x] = _palette[color];
      }
      if (reg[0].bit5) {
        _back.fillRange(out, out + 8, backdrop);
      }
      return;
    }

    final backdrop = reg[7].mask4;
    if (!displayOn) {
      _back.fillRange(out, out + width, tmsPalette[backdrop]);
      return;
    }
    _renderBgTms(y);
    if (!reg[1].bit4) {
      _renderSpritesTms(y);
    } else {
      _spriteLine.fillRange(0, width, 0);
    }
    for (var x = 0; x < width; x++) {
      var color = _spriteLine[x];
      if (color == 0) color = _bgLine[x];
      if (color == 0) color = backdrop;
      _back[out + x] = tmsPalette[color];
    }
  }

  /// mode 4 background: stores the color index (bit 4: sprite palette) and
  /// the priority (bit 5) of each pixel
  void _renderBg4(int y) {
    final tall = activeLines == 224;
    final nameBase =
        tall ? (reg[2] & 0x0c).shl10 | 0x700 : (reg[2] & 0x0e).shl10;
    final hscroll = reg[0].bit6 && y < 16 ? 0 : reg[8];
    for (var x = 0; x < width; x++) {
      final column = x.shr3;
      final vscroll = reg[0].bit7 && column >= 24 ? 0 : _vscroll;
      final row = tall ? (y + vscroll).mask8 : (y + vscroll) % 224;
      final bgx = (x - hscroll).mask8;
      final entryAddr = nameBase + row.shr3 * 64 + bgx.shr3 * 2;
      final entry = vram[entryAddr.mask14] | vram[(entryAddr + 1).mask14].shl8;
      final tile = entry.mask9;
      final tileRow = entry.bit10 ? 7 - row.mask3 : row.mask3;
      final tileCol = entry.bit9 ? 7 - bgx.mask3 : bgx.mask3;
      final color = _pixel4(tile * 32 + tileRow * 4, tileCol);
      _bgLine[x] = color | (entry.bit11 ? 0x10 : 0) | (entry.bit12 ? 0x20 : 0);
    }
  }

  int _pixel4(int addr, int col) {
    final shift = 7 - col;
    return vram[addr].shr(shift).mask1 |
        vram[addr + 1].shr(shift).mask1.shl1 |
        vram[addr + 2].shr(shift).mask1.shl2 |
        vram[addr + 3].shr(shift).mask1.shl3;
  }

  int get _spriteHeight => (reg[1].bit1 ? 16 : 8) * (reg[1].bit0 ? 2 : 1);

  /// the row of the sprite [i] at the line [y], or -1 when it is not on it
  int _spriteRow(int i, int y) {
    final sy = vram[(reg[5] & 0x7e).shl7 + i];
    final row = (y - sy - 1).mask8;
    return row < _spriteHeight ? row : -1;
  }

  bool _spriteEnd(int i) =>
      activeLines == 192 && vram[(reg[5] & 0x7e).shl7 + i] == 0xd0;

  /// sets the overflow flag when more than 8 sprites are on the line [y]
  void _evaluateSprites4(int y) {
    if (!mode4 || !displayOn) return;
    var count = 0;
    for (var i = 0; i < 64 && !_spriteEnd(i); i++) {
      if (_spriteRow(i, y) >= 0 && ++count > 8) {
        _overflow = true;
        return;
      }
    }
  }

  void _renderSprites4(int y) {
    _spriteLine.fillRange(0, width, 0);
    final satBase = (reg[5] & 0x7e).shl7;
    final patternBase = reg[6].bit2 ? 0x2000 : 0;
    final tall = reg[1].bit1;
    final zoom = reg[1].bit0 ? 2 : 1;
    var count = 0;
    for (var i = 0; i < 64 && !_spriteEnd(i) && count < 8; i++) {
      final spriteRow = _spriteRow(i, y);
      if (spriteRow < 0) continue;
      count++;
      var sx = vram[satBase + 0x80 + i * 2];
      if (reg[0].bit3) sx -= 8;
      var tile = vram[satBase + 0x81 + i * 2];
      if (tall) tile &= 0xfe;
      final row = spriteRow ~/ zoom;
      final addr = patternBase + tile * 32 + row * 4;
      for (var px = 0; px < 8 * zoom; px++) {
        final x = sx + px;
        if (x < 0 || x >= width) continue;
        final color = _pixel4(addr.mask14, px ~/ zoom);
        if (color == 0) continue;
        if (_spriteLine[x] != 0) {
          _collision = true;
          continue;
        }
        _spriteLine[x] = 16 | color;
      }
    }
  }

  /// TMS9918A graphics I/II, text and multicolor modes. stores the color of
  /// each pixel, 0 for transparent
  void _renderBgTms(int y) {
    final m1 = reg[1].bit4, m2 = reg[0].bit1, m3 = reg[1].bit3;
    final nameBase = reg[2].mask4.shl10;
    final row = y.shr3;

    if (m1) {
      // text: 40 columns of 6 pixels
      final fg = reg[7].shr4, bg = reg[7].mask4;
      _bgLine.fillRange(0, width, bg);
      final patternBase = reg[4].mask3.shl11;
      for (var column = 0; column < 40; column++) {
        final name = vram[(nameBase + row * 40 + column).mask14];
        final bits = vram[(patternBase + name * 8 + y.mask3).mask14];
        for (var px = 0; px < 6; px++) {
          _bgLine[8 + column * 6 + px] = bits.shl(px).bit7 ? fg : bg;
        }
      }
      return;
    }

    for (var column = 0; column < 32; column++) {
      final name = vram[(nameBase + row * 32 + column).mask14];
      int bits, colors;
      if (m3) {
        // multicolor: 4x4 blocks
        final addr =
            reg[4].mask3.shl11 + name * 8 + (row & 3) * 2 + y.shr2.mask1;
        final value = vram[addr.mask14];
        bits = 0xf0;
        colors = value;
      } else if (m2) {
        final index = (row.shr3.shl8 | name).shl3 | y.mask3;
        final patternAddr =
            (reg[4] & 4).shl11 | index & ((reg[4] & 3).shl11 | 0x7ff);
        final colorAddr =
            (reg[3] & 0x80).shl6 | index & ((reg[3] & 0x7f).shl6 | 0x3f);
        bits = vram[patternAddr.mask14];
        colors = vram[colorAddr.mask14];
      } else {
        bits = vram[(reg[4].mask3.shl11 + name * 8 + y.mask3).mask14];
        colors = vram[(reg[3].shl6 + name.shr3).mask14];
      }
      final fg = colors.shr4, bg = colors.mask4;
      for (var px = 0; px < 8; px++) {
        _bgLine[column * 8 + px] = bits.shl(px).bit7 ? fg : bg;
      }
    }
  }

  void _renderSpritesTms(int y) {
    _spriteLine.fillRange(0, width, 0);
    final satBase = reg[5].mask7.shl7;
    final patternBase = reg[6].mask3.shl11;
    final large = reg[1].bit1;
    final zoom = reg[1].bit0 ? 2 : 1;
    final size = (large ? 16 : 8) * zoom;
    var count = 0;
    _fifthSprite = 31;
    for (var i = 0; i < 32; i++) {
      final addr = satBase + i * 4;
      final sy = vram[addr];
      if (sy == 0xd0) {
        _fifthSprite = i;
        break;
      }
      var top = sy + 1;
      if (top > 0xe0) top -= 256;
      if (y < top || y >= top + size) continue;
      if (count == 4) {
        if (!_overflow) {
          _overflow = true;
          _fifthSprite = i;
        }
        break;
      }
      count++;
      final attr = vram[addr + 3];
      final color = attr.mask4;
      var sx = vram[addr + 1];
      if (attr.bit7) sx -= 32;
      var name = vram[addr + 2];
      if (large) name &= 0xfc;
      final row = (y - top) ~/ zoom;
      for (var px = 0; px < size; px++) {
        final x = sx + px;
        if (x < 0 || x >= width) continue;
        final col = px ~/ zoom;
        // 16x16 sprites are made of 4 patterns: top left, bottom left,
        // top right and bottom right
        final pattern = name + (col.shr3.shl1 | row.shr3);
        final bits = vram[(patternBase + pattern * 8 + row.mask3).mask14];
        if (!bits.shl(col.mask3).bit7) continue;
        if (_spriteHit[x] != 0) {
          _collision = true;
          continue;
        }
        _spriteHit[x] = 1;
        if (color != 0) _spriteLine[x] = color;
      }
    }
    _spriteHit.fillRange(0, width, 0);
  }

  // ----------------------------------------------------------------------
  // debug

  String dump() =>
      "vdp: ${List.generate(11, (i) => reg[i].x2).join(" ")} line:$line "
      "addr:${_addr.x4} code:$_code ${mode4 ? "m4" : "tms"} "
      "int:${_frameInt ? 1 : 0}${_lineInt ? 1 : 0} lc:${_lineCounter.x2}";

  /// renders the 512 patterns of the mode 4, or 256 patterns of TMS modes,
  /// with the [paletteNo] palette
  ImageBuffer renderPatterns(int paletteNo) {
    const w = 128;
    final tiles = mode4 ? 512 : 768;
    final h = tiles ~/ 16 * 8;
    final buf = Uint32List(w * h);
    for (var t = 0; t < tiles; t++) {
      final ox = t.mask4 * 8, oy = t.shr4 * 8;
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          final int color;
          if (mode4) {
            color = _palette[paletteNo.mask1 * 16 + _pixel4(t * 32 + y * 4, x)];
          } else {
            final bits = vram[(t * 8 + y).mask14];
            color = tmsPalette[bits.shl(x).bit7 ? 15 : 1];
          }
          buf[(oy + y) * w + ox + x] = color;
        }
      }
    }
    return ImageBuffer(w, h, buf);
  }

  ImageBuffer renderColors() {
    const block = 8;
    final count = mode4 ? 32 : 16;
    final buf = Uint32List(16 * block * (count ~/ 16) * block);
    for (var i = 0; i < count; i++) {
      final color = mode4 ? _palette[i] : tmsPalette[i];
      final ox = i.mask4 * block, oy = i.shr4 * block;
      for (var y = 0; y < block; y++) {
        buf.fillRange((oy + y) * 16 * block + ox,
            (oy + y) * 16 * block + ox + block, color);
      }
    }
    return ImageBuffer(16 * block, count ~/ 16 * block, buf);
  }
}
