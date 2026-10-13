part of 'ppu.dart';

extension PpuVideoDebug on Ppu {
  int get _debugBackground => Ppu._rgba[_pal(0).mask15];
  bool _debugText(int bg) =>
      _io16(0).mask3 == 0 || _io16(0).mask3 == 1 && bg < 2;
  bool _debugBitmap(int bg) => bg == 2 && _io16(0).mask3 >= 3;
  List<int> get _debugBgs => switch (_io16(0).mask3) {
        0 => [0, 1, 2, 3],
        1 => [0, 1, 2],
        2 => [2, 3],
        _ => [2]
      };
  List<DebugPalette> _debugPalettes(int bits, int base, String name) => [
        for (var p = 0; p < (bits == 8 ? 1 : 16); p++)
          DebugPalette('$name $p', [
            for (var c = 0; c < (1 << bits); c++)
              Ppu._rgba[_pal(base + p * (1 << bits) + c).mask15]
          ]),
      ];
  List<DebugPatternTable> get debugPatternTables => [
        for (final bg in _debugBgs)
          if (!_debugBitmap(bg)) _debugBgPatterns(bg),
        for (final bits in [4, 8])
          DebugPatternTable('OBJ ($bits bpp)',
              kind: DebugLayerKind.sprites,
              count: bits == 4 ? 1024 : 512,
              patternNumber: (n) => bits == 8 ? n * 2 : n,
              colorCount: 1 << bits,
              originalBackground: _debugBackground,
              palettes: _debugPalettes(bits, 256, 'OBJ'),
              readPixel: (n, x, y) => debugPackedPixel(
                  (a) => bus.vram[0x10000 + (a & 0x7fff)], n * bits * 8, x, y,
                  bits: bits, stride: bits)),
      ];
  DebugPatternTable _debugBgPatterns(int bg) {
    final cnt = _io16(8 + bg * 2), bits = !_debugText(bg) || cnt.bit7 ? 8 : 4;
    final base = cnt.shr2.mask2 * 0x4000;
    return DebugPatternTable('BG$bg ($bits bpp)',
        count: _debugText(bg) ? 1024 : 256,
        colorCount: 1 << bits,
        originalBackground: _debugBackground,
        palettes: _debugPalettes(bits, 0, 'BG'), readPixel: (n, x, y) {
      final a = base + n * bits * 8;
      return debugPackedPixel(
          (address) => address < 0x10000 ? bus.vram[address] : 0, a, x, y,
          bits: bits, stride: bits);
    });
  }

  List<DebugVideoLayer> get debugVideoLayers => [
        for (final bg in _debugBgs)
          DebugVideoLayer('BG$bg${_debugBitmap(bg) ? " (bitmap)" : ""}',
              (map) => map ? _debugBgMap(bg) : _debugScreen(bg),
              hasMap: true, originalBackground: _debugBackground),
        DebugVideoLayer(
            'Sprites', (map) => map ? _debugSpriteMap() : _debugScreen(4),
            kind: DebugLayerKind.sprites,
            hasMap: true,
            originalBackground: _debugBackground),
      ];
  DebugRaster _debugScreen(int layer) {
    final copy = Ppu(bus), canvas = DebugCanvas(Ppu.width, Ppu.height);
    final dispcnt = _io16(0), mode = dispcnt.mask3;
    if (dispcnt.bit7 || dispcnt & (1 << (8 + layer)) == 0) {
      return canvas.raster();
    }
    for (var y = 0; y < Ppu.height; y++) {
      for (var i = 0; i < 2; i++) {
        copy._refX[i] =
            _io32(0x28 + i * 16).rel28 + _io16(0x22 + i * 16).rel16 * y;
        copy._refY[i] =
            _io32(0x2c + i * 16).rel28 + _io16(0x26 + i * 16).rel16 * y;
      }
      copy._renderBackgrounds(mode, dispcnt, y);
      copy._renderObjects(dispcnt, y);
      for (var x = 0; x < Ppu.width; x++) {
        final color = layer == 4
            ? copy._objColor[x]
            : copy._bgActive[layer]
                ? copy._bg[layer][x]
                : -1;
        final mask = copy._windowMask(dispcnt, x, y);
        if (color >= 0 && mask & (1 << layer) != 0) {
          canvas.pixels[y * Ppu.width + x] = Ppu._rgba[color.mask15];
        }
      }
    }
    if (layer < 4 && _debugText(layer)) {
      final map = _debugBgMap(layer);
      canvas.patterns.addAll(map
          .cropWrapped(_io16(0x10 + layer * 4).mask9,
              _io16(0x12 + layer * 4).mask9, Ppu.width, Ppu.height)
          .patterns);
    } else if (layer < 4 && !_debugBitmap(layer)) {
      _debugAffineAnnotations(layer, canvas);
    } else if (layer == 4) _debugObjectAnnotations(canvas, false);
    return canvas.raster();
  }

  DebugRaster _debugBgMap(int bg) {
    final cnt = _io16(8 + bg * 2), size = cnt.shr14.mask2;
    if (_debugBitmap(bg)) {
      final mode = _io16(0).mask3,
          w = mode == 5 ? 160 : 240,
          h = mode == 5 ? 128 : 160;
      final base = mode != 3 && _io16(0).bit4 ? 0xa000 : 0;
      final canvas = DebugCanvas(w, h);
      for (var y = 0; y < h; y++)
        for (var x = 0; x < w; x++) {
          final value = mode == 4
              ? _pal(bus.vram[base + y * w + x])
              : _vram16(base + (y * w + x) * 2);
          canvas.pixels[y * w + x] = Ppu._rgba[value.mask15];
        }
      canvas.viewports.add(_debugAffineViewport(bg));
      return canvas.raster();
    }
    final text = _debugText(bg), pixels = text ? 256 : 128 << size;
    final w = text && size.bit0 ? 512 : pixels,
        h = text && size.bit1 ? 512 : pixels;
    final canvas = DebugCanvas(w, h),
        screenBase = cnt.shr8.mask5 * 0x800,
        charBase = cnt.shr2.mask2 * 0x4000;
    final bits = !text || cnt.bit7 ? 8 : 4;
    for (var y = 0; y < h ~/ 8; y++)
      for (var x = 0; x < w ~/ 8; x++) {
        var block = 0;
        if (text) {
          block = size == 1
              ? x ~/ 32
              : size == 2
                  ? y ~/ 32
                  : size == 3
                      ? (y ~/ 32) * 2 + x ~/ 32
                      : 0;
        }
        final address = screenBase +
            (text
                ? block * 0x800 + ((y & 31) * 32 + (x & 31)) * 2
                : y * (w ~/ 8) + x);
        final entry = text ? _vram16(address) : bus.vram[address & 0xffff];
        final number = text ? entry.mask10 : entry;
        canvas.tile(number, x * 8, y * 8, 8, 8, (px, py) {
          final a = charBase + number * bits * 8;
          final c = debugPackedPixel(
              (addr) => addr < 0x10000 ? bus.vram[addr] : 0, a, px, py,
              bits: bits, stride: bits);
          if (c == 0) return 0;
          return Ppu
              ._rgba[_pal(c + (bits == 4 ? entry.shr12.mask4 * 16 : 0)).mask15];
        }, flipX: text && entry.bit10, flipY: text && entry.bit11);
      }
    if (text) {
      canvas.viewport(_io16(0x10 + bg * 4).mask9, _io16(0x12 + bg * 4).mask9,
          Ppu.width, Ppu.height);
    } else {
      canvas.viewports.add(_debugAffineViewport(bg));
    }
    return canvas.raster();
  }

  (double, double) _debugAffinePosition(int bg, double x, double y) {
    final i = bg - 2, base = 0x20 + i * 16;
    return (
      (_io32(base + 8).rel28 +
              _io16(base).rel16 * x +
              _io16(base + 2).rel16 * y) /
          256,
      (_io32(base + 12).rel28 +
              _io16(base + 4).rel16 * x +
              _io16(base + 6).rel16 * y) /
          256
    );
  }

  DebugOutline _debugAffineViewport(int bg) => DebugOutline([
        _debugAffinePosition(bg, 0, 0),
        _debugAffinePosition(bg, Ppu.width.toDouble(), 0),
        _debugAffinePosition(bg, Ppu.width.toDouble(), Ppu.height.toDouble()),
        _debugAffinePosition(bg, 0, Ppu.height.toDouble())
      ]);
  void _debugAffineAnnotations(int bg, DebugCanvas canvas) {
    final map = _debugBgMap(bg), origin = _debugAffinePosition(bg, 0, 0);
    final px = _debugAffinePosition(bg, 1, 0),
        py = _debugAffinePosition(bg, 0, 1);
    final a = px.$1 - origin.$1,
        b = py.$1 - origin.$1,
        c = px.$2 - origin.$2,
        d = py.$2 - origin.$2;
    canvas.projectPatterns(map, DebugAffine(a, b, c, d, origin.$1, origin.$2),
        wrap: _io16(8 + bg * 2).bit13);
  }

  void _debugObjectAnnotations(DebugCanvas canvas, bool map) {
    for (var n = 0; n < 128; n++) {
      final a0 = _oam16(n * 8), a1 = _oam16(n * 8 + 2), a2 = _oam16(n * 8 + 4);
      final mode = a0.shr8.mask2, shape = a0.shr14.mask2;
      if (mode == 2 || shape == 3) continue;
      final size = a1.shr14.mask2,
          w = Ppu._objSize[shape][size][0],
          h = Ppu._objSize[shape][size][1];
      final rawX = a1.mask9, rawY = a0.mask8;
      final x = map
              ? rawX
              : rawX >= 256
                  ? rawX - 512
                  : rawX,
          y = rawY >= 160 && !map ? rawY - 256 : rawY;
      final affine = mode == 1 || mode == 3, doubled = mode == 3;
      if (affine) {
        final bw = doubled ? w * 2 : w, bh = doubled ? h * 2 : h;
        final matrix = a1.shr9.mask5 * 32;
        final pa = _oam16(matrix + 6).rel16 / 256,
            pb = _oam16(matrix + 14).rel16 / 256;
        final pc = _oam16(matrix + 22).rel16 / 256,
            pd = _oam16(matrix + 30).rel16 / 256;
        final transform = DebugAffine(
            pa,
            pb,
            pc,
            pd,
            w / 2 - pa * (x + bw / 2) - pb * (y + bh / 2),
            h / 2 - pc * (x + bw / 2) - pd * (y + bh / 2));
        final inverse = transform.inverse;
        if (inverse == null) continue;
        final units = a0.bit13 ? 2 : 1,
            stride = _io16(0).bit6 ? w ~/ 8 * units : 32;
        final base = a2.mask10 & (a0.bit13 ? ~1 : ~0);
        for (var ty = 0; ty < h ~/ 8; ty++)
          for (var tx = 0; tx < w ~/ 8; tx++) {
            final number = base + ty * stride + tx * units;
            final tile = DebugOutline.rect(tx * 8, ty * 8, 8, 8,
                label: number.toRadixString(16).toUpperCase());
            final outline = inverse.outline(tile).clipped(
                x.toDouble(), y.toDouble(), bw.toDouble(), bh.toDouble());
            if (outline.hasArea) canvas.patterns.add(outline);
          }
      } else {
        final units = a0.bit13 ? 2 : 1,
            stride = _io16(0).bit6 ? w ~/ 8 * units : 32;
        final base = a2.mask10 & (a0.bit13 ? ~1 : ~0);
        for (var ty = 0; ty < h ~/ 8; ty++)
          for (var tx = 0; tx < w ~/ 8; tx++) {
            final number = base + ty * stride + tx * units;
            canvas.patterns.add(DebugOutline.rect(
                x + (a1.bit12 ? w - 8 - tx * 8 : tx * 8),
                y + (a1.bit13 ? h - 8 - ty * 8 : ty * 8),
                8,
                8,
                label: number.toRadixString(16).toUpperCase()));
          }
      }
    }
  }

  DebugRaster _debugSpriteMap() {
    final canvas = DebugCanvas(512, 256),
        priority = Uint8List(512 * 256)..fillRange(0, 512 * 256, 4);
    for (var n = 127; n >= 0; n--) {
      final a0 = _oam16(n * 8), a1 = _oam16(n * 8 + 2), a2 = _oam16(n * 8 + 4);
      final mode = a0.shr8.mask2, shape = a0.shr14.mask2;
      if (mode == 2 || shape == 3 || a0.shr10.mask2 == 2) continue;
      final w = Ppu._objSize[shape][a1.shr14.mask2][0],
          h = Ppu._objSize[shape][a1.shr14.mask2][1];
      final affine = mode == 1 || mode == 3,
          bw = mode == 3 ? w * 2 : w,
          bh = mode == 3 ? h * 2 : h;
      final x = a1.mask9,
          y = a0.mask8,
          bits = a0.bit13 ? 8 : 4,
          units = bits == 8 ? 2 : 1;
      final stride = _io16(0).bit6 ? w ~/ 8 * units : 32,
          base = a2.mask10 & (bits == 8 ? ~1 : ~0);
      final matrix = a1.shr9.mask5 * 32, prio = a2.shr10.mask2;
      for (var dy = 0; dy < bh; dy++)
        for (var dx = 0; dx < bw; dx++) {
          var sx = dx, sy = dy;
          if (affine) {
            sx = (_oam16(matrix + 6).rel16 * (dx - bw ~/ 2) +
                        _oam16(matrix + 14).rel16 * (dy - bh ~/ 2))
                    .shr8 +
                w ~/ 2;
            sy = (_oam16(matrix + 22).rel16 * (dx - bw ~/ 2) +
                        _oam16(matrix + 30).rel16 * (dy - bh ~/ 2))
                    .shr8 +
                h ~/ 2;
          } else {
            if (a1.bit12) sx = w - 1 - sx;
            if (a1.bit13) sy = h - 1 - sy;
          }
          if (sx < 0 || sx >= w || sy < 0 || sy >= h) continue;
          final number = base + sy ~/ 8 * stride + sx ~/ 8 * units;
          final c = debugPackedPixel((a) => bus.vram[0x10000 + (a & 0x7fff)],
              number * 32, sx & 7, sy & 7,
              bits: bits, stride: bits);
          if (c == 0) continue;
          final dest = ((y + dy) & 255) * 512 + ((x + dx) & 511);
          if (prio <= priority[dest]) {
            priority[dest] = prio;
            canvas.pixels[dest] = Ppu._rgba[
                _pal(256 + (bits == 4 ? a2.shr12.mask4 * 16 : 0) + c).mask15];
          }
        }
    }
    _debugObjectAnnotations(canvas, true);
    canvas.viewport(0, 0, Ppu.width, Ppu.height);
    return canvas.raster();
  }
}
