import '../../video_debug.dart';
import 'ppu.dart';

extension PpuVideoDebug on Ppu {
  int _pixel(int number, int x, int y) => debugPlanarPixel(
      (a) => vram[a & 0x1fff], number * 16, x, y, const [0, 1]);
  int _color(int palette, int index) =>
      Ppu.colors[(palette >> (index * 2)) & 3];
  int get _background => _color(bgp, 0);
  List<DebugPatternTable> get debugPatternTables => [
        DebugPatternTable('BG / Sprites (shared)',
            count: 384,
            colorCount: 4,
            originalBackground: _background,
            readPixel: _pixel,
            palettes: [
              for (final p in [('BG', bgp), ('OBJ 0', obp0), ('OBJ 1', obp1)])
                DebugPalette(
                    p.$1, [for (var c = 0; c < 4; c++) _color(p.$2, c)])
            ]),
      ];
  List<DebugVideoLayer> get debugVideoLayers => [
        DebugVideoLayer('BG', (map) => _backgroundMap(false, map),
            hasMap: true, originalBackground: _background),
        DebugVideoLayer('Window', (map) => _backgroundMap(true, map),
            hasMap: true, originalBackground: _background),
        DebugVideoLayer('Sprites', (_) => _sprites(),
            kind: DebugLayerKind.sprites, originalBackground: _background),
      ];
  DebugRaster _backgroundMap(bool window, bool map) {
    final canvas = DebugCanvas(256, 256);
    final base = (lcdc & (window ? 0x40 : 8)) != 0 ? 0x1c00 : 0x1800;
    for (var y = 0; y < 32; y++) {
      for (var x = 0; x < 32; x++) {
        final tile = vram[base + y * 32 + x];
        final number =
            lcdc & 0x10 != 0 ? tile : 256 + (tile >= 128 ? tile - 256 : tile);
        canvas.tile(number, x * 8, y * 8, 8, 8,
            (px, py) => _color(bgp, _pixel(number, px, py)));
      }
    }
    if (!window) {
      canvas.viewport(scx, scy, 160, 144);
    } else {
      canvas.viewport(
          0, 0, (160 - (wx - 7)).clamp(0, 256), (144 - wy).clamp(0, 256));
    }
    if (map) return canvas.raster();
    if (!lcdOn || lcdc & 1 == 0 || window && lcdc & 0x20 == 0)
      return DebugCanvas(160, 144).raster();
    if (!window) return canvas.raster().cropWrapped(scx, scy, 160, 144);
    final out = DebugCanvas(160, 144);
    final source = canvas.pixels;
    for (var y = wy.clamp(0, 144); y < 144; y++) {
      for (var x = (wx - 7).clamp(0, 160); x < 160; x++) {
        out.pixels[y * 160 + x] =
            source[((y - wy) & 255) * 256 + ((x - wx + 7) & 255)];
      }
    }
    for (final shape in canvas.patterns) {
      out.patterns.add(shape.translated((wx - 7).toDouble(), wy.toDouble()));
    }
    return out.raster();
  }

  DebugRaster _sprites() {
    final canvas = DebugCanvas(160, 144);
    if (!lcdOn || lcdc & 2 == 0) return canvas.raster();
    final height = lcdc & 4 != 0 ? 16 : 8;
    final order = [for (var n = 0; n < 40; n++) n]..sort((a, b) {
        final x = oam[b * 4 + 1].compareTo(oam[a * 4 + 1]);
        return x != 0 ? x : b.compareTo(a);
      });
    for (final n in order) {
      final y = oam[n * 4] - 16, x = oam[n * 4 + 1] - 8;
      final number = oam[n * 4 + 2] & (height == 16 ? 0xfe : 0xff);
      final attr = oam[n * 4 + 3];
      if (x >= 160 || y >= 144 || y + height <= 0) continue;
      canvas.tile(number, x, y, 8, height, (px, py) {
        final screenY = y + (attr & 0x40 != 0 ? height - 1 - py : py);
        var earlier = 0;
        for (var i = 0; i < n; i++) {
          final oy = oam[i * 4] - 16;
          if (screenY >= oy && screenY < oy + height) earlier++;
        }
        if (earlier >= 10) return 0;
        final color = _pixel(number + py ~/ 8, px, py % 8);
        return color == 0 ? 0 : _color(attr & 0x10 != 0 ? obp1 : obp0, color);
      }, flipX: attr & 0x20 != 0, flipY: attr & 0x40 != 0);
    }
    return canvas.raster();
  }
}
