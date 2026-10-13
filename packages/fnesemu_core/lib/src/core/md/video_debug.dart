part of 'vdp_renderer.dart';

extension VdpVideoDebug on Vdp {
  int _debugWord(int address) =>
      vram[address & 0xffff] << 8 | vram[(address + 1) & 0xffff];
  int get _debugBackground => rgba[cram[reg[7] & 63]];
  int _debugPixel(int number, int x, int y) => debugPackedPixel(
      (a) => vram[a & 0xffff], number * (isInterlaced ? 64 : 32), x, y,
      highFirst: true);
  List<DebugPatternTable> get debugPatternTables => [
        DebugPatternTable('BG / Sprites (shared)',
            count: isInterlaced ? 1024 : 2048,
            height: isInterlaced ? 16 : 8,
            colorCount: 16,
            readPixel: _debugPixel,
            originalBackground: _debugBackground,
            palettes: [
              for (var p = 0; p < 4; p++)
                DebugPalette('Palette $p',
                    [for (var c = 0; c < 16; c++) rgba[cram[p * 16 + c]]])
            ]),
      ];
  List<DebugVideoLayer> get debugVideoLayers => [
        for (var n = 0; n < 3; n++)
          DebugVideoLayer(['Plane A', 'Plane B', 'Window'][n],
              (map) => map ? _debugMap(n) : _debugScreen(n),
              hasMap: true, originalBackground: _debugBackground),
        DebugVideoLayer(
            'Sprites', (map) => map ? _debugSpriteMap() : _debugScreen(3),
            kind: DebugLayerKind.sprites,
            hasMap: true,
            originalBackground: _debugBackground),
      ];
  DebugRaster _debugMap(int n) {
    final columns = n == 2 ? (h32 ? 32 : 64) : 1 << [5, 6, 7, 7][reg[16] & 3];
    final rows = n == 2 ? 32 : 1 << [5, 6, 7, 7][(reg[16] >> 4) & 3];
    final tileHeight = isInterlaced ? 16 : 8;
    final canvas = DebugCanvas(columns * 8, rows * tileHeight);
    final base = n == 0
        ? (reg[2] << 10) & 0xe000
        : n == 1
            ? (reg[4] << 13) & 0xe000
            : (reg[3] << 10) & (h32 ? 0xfc00 : 0xf800);
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < columns; x++) {
        final entry = _debugWord(base + (y * columns + x) * 2);
        final number = entry & 0x7ff, palette = (entry >> 13) & 3;
        canvas.tile(number, x * 8, y * tileHeight, 8, tileHeight, (px, py) {
          final index = _debugPixel(number, px, py);
          return index == 0 ? 0 : rgba[cram[palette * 16 + index]];
        }, flipX: entry & 0x800 != 0, flipY: entry & 0x1000 != 0);
      }
    }
    if (n == 2) {
      canvas.viewport(0, 0, width, Vdp.height);
    } else {
      final mode = reg[11] & 3, baseH = (reg[13] << 10) & 0xfc00;
      if (mode & 2 == 0 && !vScr2Cell) {
        canvas.viewport(-_debugWord(baseH + n * 2), vsram[n], width,
            Vdp.height * (isInterlaced ? 2 : 1));
      } else {
        for (var y = 0; y < Vdp.height; y++) {
          final line = mode & 2 == 0
              ? 0
              : mode & 1 != 0
                  ? y
                  : y & ~7;
          final sx = -_debugWord(baseH + line * 4 + n * 2);
          if (!vScr2Cell) {
            canvas.viewport(sx, vsram[n] + y, width, 1);
          } else {
            for (var x = 0; x < width; x += 16) {
              canvas.viewport(sx + x, vsram[(x ~/ 16 * 2 + n) & 63] + y, 16, 1);
            }
          }
        }
      }
    }
    return canvas.raster();
  }

  Vdp _debugClone() {
    final copy = Vdp();
    copy.vram.setAll(0, vram);
    copy.cram.setAll(0, cram);
    copy.vsram.setAll(0, vsram);
    copy.reg.setAll(0, reg);
    copy.width = width;
    copy.h32 = h32;
    copy.interlaceMode = interlaceMode;
    copy.oddFrame = oddFrame;
    return copy;
  }

  DebugRaster _debugScreen(int n) {
    final copy = _debugClone(), canvas = DebugCanvas(width, Vdp.height);
    final regions = DebugPatternRegions(width, Vdp.height);
    if (!enableDisplay) return canvas.raster();
    for (var y = 0; y < Vdp.height; y++) {
      copy.vCounter = y + 1;
      copy.renderLine(); // only the copy's counters and scratch buffers change
      final state = copy.line;
      final mode = reg[11] & 3;
      final line = mode & 2 == 0
          ? 0
          : mode & 1 != 0
              ? y
              : y & ~7;
      final hbase = ((reg[13] << 10) & 0xfc00) + line * 4;
      state.a.init((reg[2] << 10) & 0xe000, _debugWord(hbase) & 1023, 0, 0);
      state.b.init((reg[4] << 13) & 0xe000, _debugWord(hbase + 2) & 1023, 0, 0);
      state.window.init((reg[3] << 10) & (h32 ? 0xfc00 : 0xf800), 0,
          state.yy & state.maskTileYOffset, state.yy >> state.bitsTileV);
      copy._setVScroll(state.a, vsram[0]);
      copy._setVScroll(state.b, vsram[1]);
      final wh0 = reg[17] & 0x80 != 0 ? 0 : (reg[17] & 31) * 16;
      final wh1 = reg[17] & 0x80 != 0 ? (reg[17] & 31) * 16 : width;
      final wv0 = reg[18] & 0x80 != 0 ? 0 : (reg[18] & 31) * 8;
      final wv1 = reg[18] & 0x80 != 0 ? (reg[18] & 31) * 8 : Vdp.height;
      for (var x = 0; x < width; x++) {
        if (vScr2Cell && x % 16 == 0) {
          copy._setVScroll(state.a, vsram[(x ~/ 16 * 2) & 63]);
          copy._setVScroll(state.b, vsram[(x ~/ 16 * 2 + 1) & 63]);
        }
        final aRegion = x >= wh0 && x < wh1 && y >= wv0 && y < wv1;
        final pixel = switch (n) {
          0 => aRegion ? copy._planeColor(state.a, x) : 0,
          1 => copy._planeColor(state.b, x),
          2 => !aRegion ? copy._windowColor(state.window, x) : 0,
          _ => state.spLine[x],
        };
        if (n < 3 && (n == 1 || (n == 0 ? aRegion : !aRegion))) {
          final ctx = n == 0
              ? state.a
              : n == 1
                  ? state.b
                  : state.window;
          final sx = n == 2 ? x : (x - ctx.hScroll) & state.maskScrollH;
          final ty = ctx.tileY, tx = sx >> 3;
          final address = n == 2
              ? ctx.nameAddrBase |
                  ((h32 ? tx & 31 : tx & 63) << 1) |
                  ((state.y >> 3) << (h32 ? 6 : 7))
              : ctx.nameAddrBase |
                  ((tx & state.maskBgWidth | ty << state.bitsBgWidth) << 1);
          regions.mark(x, y, (tx, ty), _debugWord(address) & 0x7ff);
        }
        if (pixel & 15 != 0) {
          canvas.pixels[y * width + x] = rgba[cram[pixel & 63]];
        }
      }
    }
    if (n < 3) {
      canvas.patterns.addAll(regions.outlines());
    } else {
      canvas.patterns.addAll(
          _debugSpriteMap().cropWrapped(128, 128, width, Vdp.height).patterns);
    }
    return canvas.raster();
  }

  DebugRaster _debugSpriteMap() {
    final canvas = DebugCanvas(512, 512);
    final base = (reg[5] << 9) & (h32 ? 0xfe00 : 0xfc00);
    var n = 0;
    final sprites = <Sprite>[];
    for (var count = 0; count < (h32 ? 64 : 80); count++) {
      final a = base + n * 8;
      final sprite = Sprite.of(_debugWord(a), _debugWord(a + 2),
          _debugWord(a + 4), _debugWord(a + 6),
          interlaced: isInterlaced);
      sprites.add(sprite);
      n = sprite.next;
      if (n == 0) break;
    }
    for (final sprite in sprites.reversed) {
      final tileHeight = isInterlaced ? 16 : 8;
      final totalH = sprite.vCells * tileHeight;
      for (var ty = 0; ty < sprite.vCells; ty++) {
        for (var tx = 0; tx < sprite.width ~/ 8; tx++) {
          final number = (sprite.patternAddr ~/ 32) + tx * sprite.vCells + ty;
          canvas.tile(
              number,
              sprite.x + (sprite.hFlip ? sprite.width - 8 - tx * 8 : tx * 8),
              sprite.y +
                  (sprite.vFlip
                      ? totalH - tileHeight - ty * tileHeight
                      : ty * tileHeight),
              8,
              tileHeight, (x, y) {
            final c = _debugPixel(number, x, y);
            return c == 0 ? 0 : rgba[cram[sprite.paletteNo + c]];
          }, flipX: sprite.hFlip, flipY: sprite.vFlip);
        }
      }
    }
    canvas.viewport(128, 128, width, Vdp.height);
    return canvas.raster();
  }
}
