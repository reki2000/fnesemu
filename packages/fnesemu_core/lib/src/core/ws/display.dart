import 'dart:typed_data';

import '../../types.dart';
import '../../util/int.dart';

/// the LCD controller of the mono and color consoles: two tile
/// layers and sprites, rendered one line at a time
class Display {
  static const width = 224;
  static const height = 144;

  /// the I/O ports 0x00-0xff, of which the display uses 0x00-0x3f and 0x60
  final Uint8List io;

  /// the internal RAM holding the tiles, maps and color palettes
  final Uint8List ram;

  final bool color;

  Display(this.io, this.ram, {required this.color});

  // the sprite table copied at the end of the frame
  final _sprites = Uint8List(128 * 4);
  int _spriteCount = 0;

  var _back = Uint32List(width * height);
  var _front = Uint32List(width * height);

  // pixel attributes of the line: color, or -1 for transparent
  final _scr1 = Int32List(width);
  final _scr2 = Int32List(width);
  final _sprite = Int32List(width);
  final _spriteHigh = Uint8List(width);

  void reset() {
    _sprites.fillRange(0, _sprites.length, 0);
    _spriteCount = 0;
    _back.fillRange(0, _back.length, 0xffffffff);
    _front.fillRange(0, _front.length, 0xffffffff);
  }

  bool get colorMode => color && io[0x60].bit7;
  bool get fourBpp => colorMode && io[0x60].bit6;
  bool get packed => colorMode && io[0x60].bit5;

  ImageBuffer get imageBuffer => ImageBuffer(width, height, _front);

  void swap() {
    final tmp = _back;
    _back = _front;
    _front = tmp;
  }

  /// copies the sprite table, done by the hardware at the end of a frame
  void latchSprites() {
    final base = (io[0x04] & (colorMode ? 0x3f : 0x1f)).shl9;
    final first = io[0x05].mask7;
    _spriteCount = io[0x06].clip(0, 128);
    for (var i = 0; i < _spriteCount; i++) {
      final src = base + ((first + i).mask7) * 4;
      _sprites.setRange(i * 4, i * 4 + 4, ram, src.mask16);
    }
  }

  static int _rgba(int r, int g, int b) => 0xff000000 | b.shl16 | g.shl8 | r;

  int _monoShade(int shade) {
    final v = 255 - shade.mask4 * 17;
    return _rgba(v, v, v);
  }

  int _poolShade(int index) =>
      _monoShade(io[0x1c + index.mask3.shr1] >> (index.bit0 ? 4 : 0));

  /// the RGBA color of the [index] of [palette]
  int _color(int palette, int index) {
    if (colorMode) {
      final addr = 0xfe00 + palette * 32 + index * 2;
      final v = ram[addr] | ram[addr + 1].shl8;
      return _rgba(v.shr8.mask4 * 17, v.shr4.mask4 * 17, v.mask4 * 17);
    }
    final entry = io[0x20 + palette * 2 + index.shr1];
    return _poolShade(entry >> (index.bit0 ? 4 : 0));
  }

  int get _backColor {
    final back = io[0x01];
    if (colorMode) return _color(back.shr4, back.mask4);
    return _poolShade(back);
  }

  bool _transparent(int palette, int index) =>
      index == 0 && (fourBpp || palette.bit2);

  /// the color index of the pixel ([x], [y]) of the tile
  int _pixel(int tile, int bank, int x, int y) {
    if (fourBpp) {
      final addr = (bank != 0 ? 0x8000 : 0x4000) + tile * 32 + y * 4;
      if (packed) {
        final b = ram[addr + x.shr1];
        return x.bit0 ? b.mask4 : b.shr4;
      }
      final shift = 7 - x;
      return ram[addr] >> shift & 1 |
          (ram[addr + 1] >> shift & 1) << 1 |
          (ram[addr + 2] >> shift & 1) << 2 |
          (ram[addr + 3] >> shift & 1) << 3;
    }
    final addr = (bank != 0 ? 0x4000 : 0x2000) + tile * 16 + y * 2;
    if (packed) {
      final b = ram[addr + x.shr2];
      return b >> (6 - x.mask2 * 2) & 3;
    }
    final shift = 7 - x;
    return ram[addr] >> shift & 1 | (ram[addr + 1] >> shift & 1) << 1;
  }

  void _renderScreen(
      Int32List out, int mapBase, int scrollX, int scrollY, int line) {
    final y = (line + scrollY).mask8;
    for (var x = 0; x < width; x++) {
      final sx = (x + scrollX).mask8;
      final addr = mapBase + (y.shr3 * 32 + sx.shr3) * 2;
      final entry = ram[addr] | ram[addr + 1].shl8;
      final tile = entry.mask9;
      final palette = entry.shr9.mask4;
      final bank = colorMode ? entry.shr13.mask1 : 0;
      final px = entry.bit14 ? 7 - sx.mask3 : sx.mask3;
      final py = entry.bit15 ? 7 - y.mask3 : y.mask3;
      final index = _pixel(tile, bank, px, py);
      out[x] = _transparent(palette, index) ? -1 : _color(palette, index);
    }
  }

  bool _inside(int x, int y, int port) =>
      x >= io[port] &&
      x <= io[port + 2] &&
      y >= io[port + 1] &&
      y <= io[port + 3];

  /// renders the [line] into the back buffer
  void renderLine(int line) {
    final out = line * width;
    if (!io[0x14].bit0) {
      _back.fillRange(out, out + width, _rgba(255, 255, 255));
      return;
    }

    final ctrl = io[0x00];
    final mapMask = colorMode ? 0x0f : 0x07;
    final back = _backColor;

    if (ctrl.bit0) {
      _renderScreen(
          _scr1, (io[0x07] & mapMask).shl11, io[0x10], io[0x11], line);
    } else {
      _scr1.fillRange(0, width, -1);
    }

    if (ctrl.bit1) {
      _renderScreen(
          _scr2, (io[0x07].shr4 & mapMask).shl11, io[0x12], io[0x13], line);
      if (ctrl.bit5) {
        final outside = ctrl.bit4;
        for (var x = 0; x < width; x++) {
          if (_inside(x, line, 0x08) == outside) _scr2[x] = -1;
        }
      }
    } else {
      _scr2.fillRange(0, width, -1);
    }

    _sprite.fillRange(0, width, -1);
    if (ctrl.bit2) _renderSprites(line, ctrl.bit3);

    for (var x = 0; x < width; x++) {
      var c = back;
      if (_scr1[x] != -1) c = _scr1[x];
      final sprite = _sprite[x];
      if (sprite != -1 && _spriteHigh[x] == 0) c = sprite;
      if (_scr2[x] != -1) c = _scr2[x];
      if (sprite != -1 && _spriteHigh[x] != 0) c = sprite;
      _back[out + x] = c;
    }
  }

  void _renderSprites(int line, bool window) {
    var count = 0;
    for (var i = 0; i < _spriteCount && count < 32; i++) {
      final attr = _sprites[i * 4] | _sprites[i * 4 + 1].shl8;
      final sy = _sprites[i * 4 + 2];
      final sx = _sprites[i * 4 + 3];
      final row = (line - sy).mask8;
      if (row >= 8) continue;
      count++;
      final tile = attr.mask9;
      final palette = 8 + attr.shr9.mask3;
      final outsideWindow = attr.bit12;
      final high = attr.bit13;
      final py = attr.bit15 ? 7 - row : row;
      for (var i = 0; i < 8; i++) {
        final x = (sx + i).mask8;
        if (x >= width || _sprite[x] != -1) continue;
        if (window && _inside(x, line, 0x0c) == outsideWindow) continue;
        final index = _pixel(tile, 0, attr.bit14 ? 7 - i : i, py);
        if (_transparent(palette, index)) continue;
        _sprite[x] = _color(palette, index);
        _spriteHigh[x] = high ? 1 : 0;
      }
    }
  }

  // ----------------------------------------------------------------------
  // debug

  ImageBuffer renderTiles(int palette) {
    const w = 256;
    final tiles = fourBpp || colorMode ? 1024 : 512;
    final h = tiles ~/ 32 * 8;
    final buf = Uint32List(w * h);
    for (var t = 0; t < tiles; t++) {
      final ox = t.mask5 * 8, oy = t.shr5 * 8;
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          buf[(oy + y) * w + ox + x] =
              _color(palette.mask4, _pixel(t.mask9, t.shr9, x, y));
        }
      }
    }
    return ImageBuffer(w, h, buf);
  }

  ImageBuffer renderColors() {
    const block = 8;
    final buf = Uint32List(16 * block * 16 * block);
    for (var p = 0; p < 16; p++) {
      for (var c = 0; c < 16; c++) {
        final color = colorMode || c < 4 ? _color(p, c) : 0xff000000;
        for (var y = 0; y < block; y++) {
          final base = (p * block + y) * 16 * block + c * block;
          buf.fillRange(base, base + block, color);
        }
      }
    }
    return ImageBuffer(16 * block, 16 * block, buf);
  }
}
