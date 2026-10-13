part of 'vdp2.dart';

extension Vdp2VideoDebug on Vdp2 {
  Vdp2 _debugClone({bool sprites = false}) {
    final copy = Vdp2();
    copy.vram.setAll(0, vram);
    copy.cram.setAll(0, cram);
    copy.regs.setAll(0, regs);
    copy._cramMask = _cramMask;
    copy._rebuildColors();
    copy._setupOffsets();
    copy.vdp1 = sprites ? vdp1.debugSnapshot() : vdp1;
    return copy;
  }

  List<DebugVideoLayer> get debugVideoLayers => [
        for (var n = 0; n < 4; n++)
          DebugVideoLayer('NBG$n', (map) => _debugNbg(n, map),
              row: n ~/ 2, hasMap: true),
        DebugVideoLayer('RBG0 A', (map) => _debugRotation(0, map),
            row: 2, hasMap: true),
        if (reg(0xb0).mask2 == 1 || reg(0xb0).mask2 == 2)
          DebugVideoLayer('RBG0 B', (map) => _debugRotation(1, map),
              row: 2, hasMap: true),
        DebugVideoLayer('VDP1 Sprites / Polygons', _debugSprites,
            kind: DebugLayerKind.sprites, row: 3, hasMap: true),
      ];
  List<DebugPalette> _debugPalettes(int size, int offset) => [
        for (var p = 0; p < 2048 ~/ size; p++)
          DebugPalette('CRAM $p', [
            for (var c = 0; c < size; c++)
              0xff000000 | _color(offset + p * size + c)
          ])
      ];
  List<DebugPatternTable> get debugPatternTables {
    final copy = _debugClone(), result = <DebugPatternTable>[];
    for (var n = 0; n < 5; n++) {
      final cfg = _MapCfg();
      if (n < 4) {
        copy._setupNbg(n, cfg);
      } else {
        final rotation = _RotParam();
        copy._setupRotCfg(rotation, 0);
        _debugCopyCfg(rotation.cfg, cfg);
      }
      if (cfg.bitmap) continue;
      final mode = cfg.colorMode, bytes = Vdp2._cellBytes[mode];
      final size = switch (mode) { 0 => 16, 1 => 256, 2 => 2048, _ => 32768 };
      result.add(DebugPatternTable(
          n < 4 ? 'NBG$n characters' : 'RBG0 characters',
          count: 0x80000 ~/ bytes,
          colorCount: size,
          directColor: mode >= 3,
          patternNumber: (n) => n * bytes ~/ 32,
          palettes: mode < 3 ? _debugPalettes(size, cfg.craOffset) : const [],
          readPixel: (number, x, y) {
            final base = number * bytes;
            if (mode == 0) {
              return debugPackedPixel((a) => vram[a & 0x7ffff], base, x, y,
                  highFirst: true);
            }
            if (mode == 1) return vram[(base + y * 8 + x) & 0x7ffff];
            if (mode == 2) {
              return vramData
                  .getUint16((base + (y * 8 + x) * 2) & 0x7fffe)
                  .mask11;
            }
            final pixel = copy._dot(cfg, base, x, y, 8, 0, 1);
            return pixel == 0 ? 0 : 0xff000000 | pixel.mask24;
          }));
    }
    final palettes = <int, List<DebugPalette>>{};
    for (final command in vdp1.debugCommands()) {
      final addr = command.$1;
      if (command.$2.mask4 > 3) continue;
      final size = vdp1.debugReadWord(addr + 10),
          w = size.shr8.mask6 * 8,
          h = size.mask8;
      if (w == 0 || h == 0) continue;
      final mode = vdp1.debugReadWord(addr + 4).shr3.mask3,
          base = vdp1.debugReadWord(addr + 8) << 3;
      final colors = switch (mode) {
        0 || 1 => 16,
        2 => 64,
        3 => 128,
        4 => 256,
        _ => 32768
      };
      final banks = mode >= 5
          ? <DebugPalette>[]
          : palettes.putIfAbsent(
              colors, () => _debugPalettes(colors, reg(0xe6).shr4.mask3.shl8));
      final selectedPalettes = mode == 1
          ? [
              DebugPalette('Command LUT', [
                for (var c = 0; c < 16; c++)
                  (() {
                    final entry = vdp1.debugReadWord(
                        (vdp1.debugReadWord(addr + 6) << 3) + c * 2);
                    return entry.bit15
                        ? debugRgb555(entry)
                        : 0xff000000 |
                            _color(entry + reg(0xe6).shr4.mask3.shl8);
                  })()
              ]),
              ...banks
            ]
          : banks;
      result.add(DebugPatternTable(
          'VDP1 texture ${base.toRadixString(16).toUpperCase()}',
          kind: DebugLayerKind.sprites,
          count: 1,
          width: w,
          height: h,
          colorCount: colors,
          directColor: mode >= 5,
          palettes: selectedPalettes,
          patternNumber: (_) => base >> 3,
          readPixel: (_, x, y) {
            if (mode < 2) {
              return debugPackedPixel((a) => vdp1.vram[a & 0x7ffff], base, x, y,
                  stride: w ~/ 2, highFirst: true);
            }
            if (mode < 5) {
              return vdp1.vram[(base + y * w + x) & 0x7ffff] & (colors - 1);
            }
            final pixel = vdp1.debugReadWord(base + (y * w + x) * 2);
            return pixel == 0 ? 0 : debugRgb555(pixel);
          }));
    }
    return result;
  }

  void _debugCopyCfg(_MapCfg from, _MapCfg to) {
    to.colorMode = from.colorMode;
    to.char16 = from.char16;
    to.bitmap = from.bitmap;
    to.bitmapW = from.bitmapW;
    to.bitmapH = from.bitmapH;
    to.bitmapAddr = from.bitmapAddr;
    to.pnSize = from.pnSize;
    to.pncn = from.pncn;
    to.planeW = from.planeW;
    to.planeH = from.planeH;
    to.mapW = from.mapW;
    to.planeAddr.setAll(0, from.planeAddr);
    to.craOffset = from.craOffset;
    to.bitmapPalette = from.bitmapPalette;
    to.transparentEnabled = from.transparentEnabled;
    to.priority = from.priority;
  }

  DebugRaster _debugMap(Vdp2 copy, _MapCfg cfg,
      {int? nbg, _RotParam? rotation}) {
    final w = cfg.bitmap ? cfg.bitmapW : cfg.mapDotsW,
        h = cfg.bitmap ? cfg.bitmapH : cfg.mapDotsH;
    final canvas = DebugCanvas(w, h);
    cfg.priority = 1;
    copy._lastCellKey = -1;
    // Finish each cell before moving on so the native cell cache also serves
    // its remaining rows instead of decoding it again on every scanline.
    final step = cfg.bitmap ? 1 : 8;
    for (var ty = 0; ty < h; ty += step) {
      for (var tx = 0; tx < w; tx += step) {
        for (var py = 0; py < step; py++) {
          final y = ty + py;
          for (var px = 0; px < step; px++) {
            final x = tx + px;
            final pixel = cfg.bitmap
                ? copy._bitmapDot(cfg, x, y)
                : copy._cellDot(cfg, x, y);
            if (pixel != 0) {
              canvas.pixels[y * w + x] = 0xff000000 | pixel.mask24;
            }
            if (!cfg.bitmap && px == 0 && py == 0) {
              canvas.patterns.add(DebugOutline.rect(x, y, 8, 8,
                  label:
                      (copy._cellAddr ~/ 32).toRadixString(16).toUpperCase()));
            }
          }
        }
      }
    }
    if (nbg != null) {
      final base = nbg < 2 ? 0x70 + nbg * 16 : 0x90 + (nbg - 2) * 4;
      final sx = reg(base).mask11, sy = reg(base + (nbg < 2 ? 4 : 2)).mask11;
      final dx =
          nbg < 2 ? (reg(base + 8).mask3 * 256 + reg(base + 10).shr8) : 256;
      final dy =
          nbg < 2 ? (reg(base + 12).mask3 * 256 + reg(base + 14).shr8) : 256;
      canvas.viewport(sx, sy, width * (dx == 0 ? 256 : dx) ~/ 256,
          height * (dy == 0 ? 256 : dy) ~/ 256);
    } else if (rotation != null) {
      final points = <(double, double)>[];
      for (final p in [(0, 0), (width, 0), (width, height), (0, height)]) {
        copy._setupRotLine(rotation, p.$2);
        points.add((
          rotation.kx * (rotation.xsp + rotation.dX * p.$1) + rotation.xp,
          rotation.ky * (rotation.ysp + rotation.dY * p.$1) + rotation.yp
        ));
      }
      canvas.viewports.add(DebugOutline(points));
    }
    return canvas.raster();
  }

  (int, int, int) _debugNbgLine(int n, int y) {
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

    return (sx, sy, dx);
  }

  DebugRaster _debugNbg(int n, bool map) {
    final copy = _debugClone(), cfg = _MapCfg();
    copy._setupNbg(n, cfg);
    if (map) return _debugMap(copy, cfg, nbg: n);
    final canvas = DebugCanvas(width, height), line = Int32List(width);
    final regions = DebugPatternRegions(width, height);
    if (!displayOn || reg(0x20) & (1 << n) == 0) return canvas.raster();
    for (var y = 0; y < height; y++) {
      line.fillRange(0, width, 0);
      copy._lastCellKey = -1;
      final visible = copy._renderNbg(n, y, width, line);
      final (sx, sy, dx) = copy._debugNbgLine(n, y);
      for (var x = 0; x < width; x++) {
        if (visible && !cfg.bitmap) {
          final px = (sx + x * dx) >> 8, py = sy >> 8;
          copy._setupCell(cfg, px, py);
          regions.mark(
              x,
              y,
              ((px % cfg.mapDotsW) ~/ 8, (py % cfg.mapDotsH) ~/ 8),
              copy._cellAddr ~/ 32);
        }
        if (line[x] != 0)
          canvas.pixels[y * width + x] =
              0xff000000 | copy._offset(Vdp2._layerNbg0 + n, line[x].mask24);
      }
    }
    canvas.patterns.addAll(regions.outlines());
    return canvas.raster();
  }

  (int, int)? _debugRotationPosition(_RotParam r, int x) {
    double kx = r.kx, ky = r.ky, xp = r.xp;

    if (r.coefEnabled) {
      final coef = _readCoef(r, r.ka + r.dkax * x);
      if (coef == Vdp2Rotation._transparentCoef) {
        return null;
      }
      final k = coef / 65536.0;
      switch (r.coefMode) {
        case 0:
          kx = k;
          ky = k;
          break;
        case 1:
          kx = k;
          break;
        case 2:
          ky = k;
          break;
        default:
          xp = k * 1024.0; // viewpoint Xp (14.10)
          break;
      }
    }

    final sx = (kx * (r.xsp + r.dX * x) + xp).floor();
    final sy = (ky * (r.ysp + r.dY * x) + r.yp).floor();
    return (sx, sy);
  }

  DebugRaster _debugRotation(int parameter, bool map) {
    final copy = _debugClone(), r = _RotParam();
    final table =
        (reg(0xbc).mask3.shl16 | reg(0xbe) & 0xfffe).shl1 + parameter * 0x80;
    copy._readRotParam(r, table);
    copy._setupRotCfg(r, parameter);
    if (map) return _debugMap(copy, r.cfg, rotation: r);
    final canvas = DebugCanvas(width, height);
    final regions = DebugPatternRegions(width, height);
    final other = _RotParam();
    if (parameter == 1 && reg(0xb0).mask2 == 2) {
      copy._readRotParam(other, table - 0x80);
      copy._setupRotCfg(other, 0);
    }
    if (!displayOn || !reg(0x20).bit4 || reg(0xb0).mask2 == 1 && parameter == 0)
      return canvas.raster();
    for (var y = 0; y < height; y++) {
      copy._setupRotLine(r, y);
      if (parameter == 1 && reg(0xb0).mask2 == 2) copy._setupRotLine(other, y);
      copy._lastCellKey = -1;
      for (var x = 0; x < width; x++) {
        if (parameter == 1 &&
            reg(0xb0).mask2 == 2 &&
            copy._debugRotationPosition(other, x) != null) continue;
        final position = copy._debugRotationPosition(r, x);
        if (position == null || r.cfg.priority == 0) continue;
        final (sx, sy) = position;
        final cfg = r.cfg;
        final mw = cfg.bitmap ? cfg.bitmapW : cfg.mapDotsW,
            mh = cfg.bitmap ? cfg.bitmapH : cfg.mapDotsH;
        if (r.overMode == 2 && (sx < 0 || sy < 0 || sx >= mw || sy >= mh) ||
            !cfg.bitmap &&
                r.overMode == 3 &&
                (sx < 0 || sy < 0 || sx >= 512 || sy >= 512)) continue;
        final pixel = copy._rotDot(r, x);
        if (pixel > 0)
          canvas.pixels[y * width + x] =
              0xff000000 | copy._offset(Vdp2._layerRbg0, pixel.mask24);
        if (!cfg.bitmap) {
          copy._setupCell(cfg, sx, sy);
          regions.mark(
              x,
              y,
              ((sx % cfg.mapDotsW) ~/ 8, (sy % cfg.mapDotsH) ~/ 8),
              copy._cellAddr ~/ 32);
        }
      }
    }
    canvas.patterns.addAll(regions.outlines());
    return canvas.raster();
  }

  DebugRaster _debugSprites(bool map) {
    final copy = _debugClone(sprites: true),
        w = map ? Vdp1.fbWidth : width,
        h = map ? Vdp1.fbHeight : height;
    if (map) copy.regs[0] &= ~0xc0;
    final canvas = DebugCanvas(w, h), line = Int32List(w);
    for (var y = 0; y < h; y++) {
      line.fillRange(0, w, 0);
      copy._renderSprite(y, w, line);
      for (var x = 0; x < w; x++) {
        if (line[x] != 0)
          canvas.pixels[y * w + x] =
              0xff000000 | copy._offset(Vdp2._layerSprite, line[x].mask24);
      }
    }
    for (final shape in vdp1.debugSpriteOutlines()) {
      if (map) {
        canvas.patterns.add(shape);
      } else {
        canvas.patterns.add(DebugOutline(
            shape.points.map((p) => (
                  p.$1 * (width >= 640 ? 2 : 1),
                  p.$2 * (doubleDensity ? 2 : 1)
                )),
            label: shape.label));
      }
    }
    if (map)
      canvas.viewport(0, 0, width >= 640 ? width ~/ 2 : width,
          doubleDensity ? height ~/ 2 : height);
    return canvas.raster();
  }
}
