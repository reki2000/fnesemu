part of 'ppu_render.dart';

extension PpuVideoDebug on Ppu {
  int _debugColor(int index) => _rgba(index);
  int _debugPixel(int base, int bpp, int number, int x, int y) =>
      debugPlanarPixel(
          (a) => vram[a & 0xffff],
          (base * 2 + number * bpp * 8) & 0xffff,
          x,
          y,
          switch (bpp) {
            2 => const [0, 1],
            4 => const [0, 1, 16, 17],
            _ => const [0, 1, 16, 17, 32, 33, 48, 49],
          });
  List<DebugPalette> _debugPalettes(int count,
          {int base = 0, String name = 'Palette'}) =>
      [
        for (var p = 0; p < (256 - base) ~/ count; p++)
          DebugPalette('$name $p', [
            for (var c = 0; c < count; c++) _debugColor(base + p * count + c)
          ]),
      ];
  List<DebugPatternTable> get debugPatternTables {
    final result = <DebugPatternTable>[];
    if (bgMode == 7) {
      result.add(DebugPatternTable('Mode 7 BG',
          count: 256,
          colorCount: 256,
          readPixel: _m7CharByte,
          palettes: _debugPalettes(256),
          originalBackground: _debugColor(0)));
    } else {
      final depths = PpuRenderer._bgBpp[bgMode] ?? const [0, 0, 0, 0];
      for (var bg = 0; bg < 4; bg++) {
        final bits = depths[bg];
        if (bits == 0) continue;
        final base = bgs[bg].charBase;
        result.add(DebugPatternTable('BG$bg ($bits bpp)',
            row: bg ~/ 2,
            count: 65536 ~/ (bits * 8),
            colorCount: 1 << bits,
            readPixel: (n, x, y) => _debugPixel(base, bits, n, x, y),
            palettes: _debugPalettes(1 << bits),
            originalBackground: _debugColor(0)));
      }
    }
    for (var bank = 0; bank < 2; bank++) {
      final base = (objBase << 13) + (bank == 0 ? 0 : (objGap + 1) << 12);
      result.add(DebugPatternTable('OBJ $bank',
          kind: DebugLayerKind.sprites,
          count: 256,
          colorCount: 16,
          readPixel: (n, x, y) => _debugPixel(base, 4, n, x, y),
          palettes: _debugPalettes(16, base: 128, name: 'OBJ'),
          originalBackground: _debugColor(0)));
    }
    return result;
  }

  List<DebugVideoLayer> get debugVideoLayers => [
        if (bgMode == 7)
          DebugVideoLayer('Mode 7 BG1', _debugMode7,
              hasMap: true, originalBackground: _debugColor(0))
        else
          for (var i = 0; i < 4; i++)
            if ((PpuRenderer._bgBpp[bgMode] ?? const [0, 0, 0, 0])[i] != 0)
              DebugVideoLayer('BG${i + 1}', (map) => _debugBg(i, map),
                  hasMap: true, originalBackground: _debugColor(0)),
        DebugVideoLayer('Sprites', _debugSprites,
            kind: DebugLayerKind.sprites,
            hasMap: true,
            originalBackground: _debugColor(0)),
      ];
  Ppu _debugClone() {
    final copy = Ppu();
    copy.vram.setAll(0, vram);
    copy.cgram.setAll(0, cgram);
    copy.oam.setAll(0, oam);
    copy.bgMode = bgMode;
    copy.width = bgMode == 5 || bgMode == 6 ? 512 : 256;
    copy.bg3Priority = bg3Priority;
    copy.brightness = brightness;
    copy.forcedBlank = forcedBlank;
    copy.mainScreenEnable = mainScreenEnable;
    copy.subScreenEnable = subScreenEnable;
    copy.objBase = objBase;
    copy.objGap = objGap;
    copy.objSizeSel = objSizeSel;
    copy.w12sel = w12sel;
    copy.w34sel = w34sel;
    copy.wobjsel = wobjsel;
    copy.w1Left = w1Left;
    copy.w1Right = w1Right;
    copy.w2Left = w2Left;
    copy.w2Right = w2Right;
    copy.wbglog = wbglog;
    copy.wobjlog = wobjlog;
    copy.tmw = tmw;
    copy.tsw = tsw;
    copy.mosaicEnable = mosaicEnable;
    copy.mosaicSize = mosaicSize;
    for (var i = 0; i < 4; i++) {
      final from = bgs[i], to = copy.bgs[i];
      to.tilemapAddr = from.tilemapAddr;
      to.wideX = from.wideX;
      to.wideY = from.wideY;
      to.charBase = from.charBase;
      to.bigChar = from.bigChar;
      to.hofs = from.hofs;
      to.vofs = from.vofs;
    }
    return copy;
  }

  DebugRaster _debugBg(int index, bool map) {
    final copy = _debugClone(), bg = bgs[index];
    final bits = PpuRenderer._bgBpp[bgMode]![index], cell = bg.bigChar ? 16 : 8;
    final mw = (bg.wideX ? 64 : 32) * cell, mh = (bg.wideY ? 64 : 32) * cell;
    final canvas = DebugCanvas(map ? mw : copy.width, map ? mh : Ppu.height);
    if (map && bgMode != 2 && bgMode != 4 && bgMode != 6) {
      // Regular maps have one rectangular annotation per native 8px tile.
      // Avoid per-pixel region IDs and contour tracing for that geometry.
      for (var y = 0; y < mh; y += 8) {
        for (var x = 0; x < mw; x += 8) {
          final entry = copy._tilemapEntryRaw(index, x, y);
          final u = entry.bit14 ? cell - 1 - x % cell : x % cell;
          final v = entry.bit15 ? cell - 1 - y % cell : y % cell;
          final number = (entry & 1023) + u ~/ 8 + v ~/ 8 * 16;
          final palette = entry.shr10.mask3;
          canvas.tile(number, x, y, 8, 8, (px, py) {
            final color = _debugPixel(bg.charBase, bits, number, px, py);
            return color == 0
                ? 0
                : _debugColor(
                    copy._bgPaletteIndex(bgMode, index, bits, palette, color));
          }, flipX: entry.bit14, flipY: entry.bit15);
        }
      }
      canvas.viewport(bg.hofs, bg.vofs + 1, copy.width, Ppu.height);
      return canvas.raster();
    }
    final regions = DebugPatternRegions(canvas.width, canvas.height);
    if (!map &&
        (forcedBlank ||
            (mainScreenEnable | subScreenEnable) & (1 << index) == 0))
      return canvas.raster();
    if (map) {
      copy.bgs[index].hofs = 0;
      copy.bgs[index].vofs = 0;
    }
    for (var y = 0; y < canvas.height; y++) {
      copy.bgRowKey.fillRange(0, 4, -1);
      copy.windowLineReady = 0;
      for (var x = 0; x < canvas.width; x++) {
        var sx = x, sy = map ? y : y + 1;
        if (!map) {
          if (mosaicEnable & (1 << index) != 0 && mosaicSize > 0)
            sx = sx ~/ (mosaicSize + 1) * (mosaicSize + 1);
          if (copy._layerMasked(index, x, tmw)) continue;
        }
        final (mx, my) = copy._bgMapPos(index, sx, sy);
        final entry = copy._tilemapEntryRaw(index, mx, my);
        final u = entry.bit14 ? cell - 1 - mx % cell : mx % cell;
        final v = entry.bit15 ? cell - 1 - my % cell : my % cell;
        final number = (entry & 1023) + u ~/ 8 + v ~/ 8 * 16;
        regions.mark(x, y, ((mx % mw) ~/ 8, (my % mh) ~/ 8), number);
        final sample = copy._bgPixel(index, bits, sx, sy);
        if (sample != _BgSample.transparent)
          canvas.pixels[y * canvas.width + x] = _debugColor(
              copy._bgPaletteIndex(bgMode, index, bits,
                  _BgSample.palette(sample), _BgSample.colorIndex(sample)));
      }
    }
    canvas.patterns.addAll(regions.outlines());
    if (map) canvas.viewport(bg.hofs, bg.vofs + 1, copy.width, Ppu.height);
    return canvas.raster();
  }

  (double, double) _debugM7Position(double x, double y) {
    final a = m7a.rel16, b = m7b.rel16, c = m7c.rel16, d = m7d.rel16;
    final px = m7x.rel13, py = m7y.rel13;
    int clip(int v) => v.bit13 ? v | ~0x3ff : v & 1023;
    final h = clip(m7hofs.rel13 - px), v = clip(m7vofs.rel13 - py);
    final sy = m7sel & 2 != 0 ? 254 - y : y + 1,
        sx = m7sel & 1 != 0 ? 255 - x : x;
    return (
      (((a * h) & ~63) +
              ((b * v) & ~63) +
              ((b * sy).toInt() & ~63) +
              px * 256 +
              a * sx) /
          256,
      (((c * h) & ~63) +
              ((d * v) & ~63) +
              ((d * sy).toInt() & ~63) +
              py * 256 +
              c * sx) /
          256
    );
  }

  DebugRaster _debugMode7(bool map) {
    final canvas = DebugCanvas(map ? 1024 : 256, map ? 1024 : Ppu.height);
    final regions = DebugPatternRegions(canvas.width, canvas.height);
    for (var y = 0; y < canvas.height; y++) {
      for (var x = 0; x < canvas.width; x++) {
        var u = x, v = y;
        if (!map) {
          if (forcedBlank || mainScreenEnable & 1 == 0) continue;
          final position = _debugM7Position(x.toDouble(), y.toDouble());
          u = position.$1.floor();
          v = position.$2.floor();
        }
        final outside = u < 0 || u >= 1024 || v < 0 || v >= 1024,
            over = m7sel >> 6 & 3;
        if (!map && outside && over == 2) continue;
        final number = !map && outside && over == 3
            ? 0
            : _m7TilemapByte((u >> 3) & 127, (v >> 3) & 127);
        regions.mark(x, y, (u ~/ 8, v ~/ 8), number);
        final color = _m7CharByte(number, u & 7, v & 7);
        if (color != 0)
          canvas.pixels[y * canvas.width + x] = _debugColor(color);
      }
    }
    canvas.patterns.addAll(regions.outlines());
    if (map)
      canvas.viewports.add(DebugOutline([
        _debugM7Position(0, 0),
        _debugM7Position(256, 0),
        _debugM7Position(256, Ppu.height.toDouble()),
        _debugM7Position(0, Ppu.height.toDouble())
      ]));
    return canvas.raster();
  }

  DebugRaster _debugSprites(bool map) {
    final copy = _debugClone(),
        screenWidth = bgMode == 5 || bgMode == 6 ? 512 : 256;
    final canvas = DebugCanvas(map ? 512 : screenWidth, map ? 256 : Ppu.height);
    if (!map &&
        (forcedBlank || (mainScreenEnable | subScreenEnable) & 16 == 0)) {
      return canvas.raster();
    }
    if (!map) {
      for (var y = 0; y < Ppu.height; y++) {
        copy.objLineColor.fillRange(0, Ppu.widthNormal, -1);
        copy._evalSprites(
            y, copy.objLineColor, copy.objLinePalette, copy.objLinePriority);
        for (var x = 0; x < screenWidth; x++) {
          final ox = screenWidth == 512 ? x ~/ 2 : x,
              color = copy.objLineColor[ox];
          if (color >= 0 && !copy._layerMasked(4, x, tmw)) {
            canvas.pixels[y * screenWidth + x] =
                _debugColor(128 + copy.objLinePalette[ox] * 16 + color);
          }
        }
      }
    }
    final sizes = PpuRenderer._objSizeTable[objSizeSel & 7];
    for (var n = 127; n >= 0; n--) {
      final base = n * 4, high = (oam[512 + (n >> 2)] >> ((n & 3) * 2)) & 3;
      final rawX = oam[base] | (high & 1) << 8,
          x = map
              ? rawX
              : rawX >= 256
                  ? rawX - 512
                  : rawX;
      final y = oam[base + 1], attr = oam[base + 3];
      final w = sizes[high & 2 != 0 ? 2 : 0], h = sizes[high & 2 != 0 ? 3 : 1];
      final name = (objBase << 13) + (attr & 1 != 0 ? (objGap + 1) << 12 : 0);
      for (var ty = 0; ty < h ~/ 8; ty++)
        for (var tx = 0; tx < w ~/ 8; tx++) {
          final number =
              (oam[base + 2] + ty * 16) & 0xf0 | (oam[base + 2] + tx) & 15;
          final dx = x + (attr & 64 != 0 ? w - 8 - tx * 8 : tx * 8);
          final dy = (y + (attr & 128 != 0 ? h - 8 - ty * 8 : ty * 8)) & 255;
          if (map) {
            canvas.tile(number, dx, dy, 8, 8, (px, py) {
              final color = _debugPixel(name, 4, number, px, py);
              return color == 0
                  ? 0
                  : _debugColor(128 + ((attr >> 1) & 7) * 16 + color);
            }, flipX: attr & 64 != 0, flipY: attr & 128 != 0, wrapY: true);
          } else {
            canvas.patterns.add(DebugOutline.rect(
                dx * (screenWidth == 512 ? 2 : 1),
                dy,
                screenWidth == 512 ? 16 : 8,
                8,
                label: number.toRadixString(16).toUpperCase()));
          }
        }
    }
    if (map) canvas.viewport(0, 0, 256, Ppu.height);
    return canvas.raster();
  }
}
