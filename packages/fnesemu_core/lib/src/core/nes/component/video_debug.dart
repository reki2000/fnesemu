import '../../../video_debug.dart';
import 'ppu.dart';
import 'ppu_render.dart';

extension PpuVideoDebug on Ppu {
  int _peek(int addr, {bool sprite = false}) =>
      bus.peekVram(addr & 0x3fff, sprite: sprite);
  int _pixel(int pattern, int x, int y, {bool sprite = false}) =>
      debugPlanarPixel(
          (a) => _peek(a, sprite: sprite), pattern * 16, x, y, const [0, 8],
          rowStride: 1);
  int _color(int bank, int color) =>
      PpuRenderer.debugColor(palette[((bank * 4 + color) & 0x1f)]);

  List<DebugPalette> get _palettes => [
        for (var bank = 0; bank < 8; bank++)
          DebugPalette('${bank < 4 ? "BG" : "OBJ"} ${bank % 4}',
              [for (var color = 0; color < 4; color++) _color(bank, color)]),
      ];
  List<DebugPatternTable> get debugPatternTables => [
        for (var bank = 0; bank < 2; bank++)
          DebugPatternTable('CHR $bank (BG / OBJ)',
              count: 256,
              colorCount: 4,
              palettes: _palettes,
              originalBackground: _color(0, 0),
              readPixel: (n, x, y) => _pixel(bank * 256 + n, x, y)),
      ];
  List<DebugVideoLayer> get debugVideoLayers => [
        DebugVideoLayer('BG', _background,
            hasMap: true, originalBackground: _color(0, 0)),
        DebugVideoLayer('Sprites', (_) => _sprites(),
            kind: DebugLayerKind.sprites, originalBackground: _color(0, 0)),
      ];

  DebugRaster _background(bool map) {
    final canvas = DebugCanvas(512, 480);
    for (var ny = 0; ny < 2; ny++) {
      for (var nx = 0; nx < 2; nx++) {
        final base = 0x2000 + (ny * 2 + nx) * 0x400;
        for (var ty = 0; ty < 30; ty++) {
          for (var tx = 0; tx < 32; tx++) {
            final number = _peek(base + ty * 32 + tx) + (bgTable() ? 256 : 0);
            final attribute = _peek(base + 0x3c0 + (ty ~/ 4) * 8 + tx ~/ 4);
            final bank = (attribute >> ((ty & 2) * 2 + (tx & 2))) & 3;
            canvas.tile(number, nx * 256 + tx * 8, ny * 240 + ty * 8, 8, 8,
                (x, y) {
              final color = _pixel(number, x, y);
              return color == 0 ? 0 : _color(bank, color);
            });
          }
        }
      }
    }
    final sx = (baseNameAddr() & 1) * 256 + scrollX;
    final sy = (baseNameAddr() >> 1) * 240 + scrollY;
    canvas.viewport(sx, sy, 256, 240);
    if (map) return canvas.raster();
    if (!showBg()) return DebugCanvas(256, 240).raster();
    final screen = canvas.raster().cropWrapped(sx, sy, 256, 240);
    if (clipLeftEdgeBg()) {
      for (var y = 0; y < 240; y++) {
        screen.image.buffer.fillRange(y * 256 * 4, (y * 256 + 8) * 4, 0);
      }
    }
    return screen;
  }

  DebugRaster _sprites() {
    final canvas = DebugCanvas(256, 240);
    if (!showSprite()) return canvas.raster();
    final height = objSize16() ? 16 : 8;
    for (var n = 63; n >= 0; n--) {
      final x = objRam[n * 4 + 3], y = objRam[n * 4] + 1;
      final attr = objRam[n * 4 + 2], tile = objRam[n * 4 + 1];
      final number = height == 16
          ? (tile & 0xfe) + (tile & 1) * 256
          : tile + (objTable() ? 256 : 0);
      if (y >= 240) continue;
      canvas.tile(number, x, y, 8, height, (px, py) {
        final screenY = y + ((attr & 0x80) != 0 ? height - 1 - py : py);
        var earlier = 0;
        for (var i = 0; i < n; i++) {
          final oy = objRam[i * 4] + 1;
          if (screenY >= oy && screenY < oy + height) earlier++;
        }
        if (earlier >= 8 ||
            clipLeftEdgeSprite() && x + (attr & 0x40 != 0 ? 7 - px : px) < 8) {
          return 0;
        }
        final color = _pixel(number + py ~/ 8, px, py % 8, sprite: true);
        return color == 0 ? 0 : _color(4 + (attr & 3), color);
      }, flipX: (attr & 0x40) != 0, flipY: (attr & 0x80) != 0);
    }
    return canvas.raster();
  }
}
