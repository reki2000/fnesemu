import '../../../video_debug.dart';
import 'vdc.dart';
import 'vdc_render.dart';

extension VdcVideoDebug on Vdc {
  int get _background => rgba[colorTable[0]];
  int _byte(int address) =>
      (vram[(address >> 1) & 0xffff] >> ((address & 1) * 8)) & 255;
  int _bgPixel(int n, int x, int y) =>
      debugPlanarPixel(_byte, n * 32, x, y, const [0, 1, 16, 17]);
  int _objPixel(int n, int x, int y) {
    var pixel = 0;
    for (var p = 0; p < 4; p++) {
      pixel |= ((vram[(n * 64 + p * 16 + y) & 0xffff] >> (15 - x)) & 1) << p;
    }
    return pixel;
  }

  List<DebugPalette> _palettes(int base) => [
        for (var p = 0; p < 16; p++)
          DebugPalette('${base == 0 ? "BG" : "OBJ"} $p', [
            for (var c = 0; c < 16; c++) rgba[colorTable[base + p * 16 + c]]
          ])
      ];
  List<DebugPatternTable> get debugPatternTables => [
        DebugPatternTable('VDC $priority BG',
            count: 4096,
            colorCount: 16,
            readPixel: _bgPixel,
            palettes: _palettes(0),
            originalBackground: _background),
        DebugPatternTable('VDC $priority Sprites',
            kind: DebugLayerKind.sprites,
            count: 1024,
            width: 16,
            height: 16,
            colorCount: 16,
            readPixel: _objPixel,
            palettes: _palettes(256),
            originalBackground: _background),
      ];
  List<DebugVideoLayer> get debugVideoLayers => [
        DebugVideoLayer('VDC $priority BG', _bgMap,
            hasMap: true, originalBackground: _background),
        DebugVideoLayer('VDC $priority Sprites', _sprites,
            kind: DebugLayerKind.sprites,
            hasMap: true,
            originalBackground: _background),
      ];
  DebugRaster _bgMap(bool map) {
    final columns = bgWidthMask + 1, rows = bgHeightMask + 1;
    final canvas = DebugCanvas(columns * 8, rows * 8);
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < columns; x++) {
        final entry = vram[(y * columns + x) & 0xffff];
        final number = entry & 0xfff, palette = entry >> 12;
        canvas.tile(number, x * 8, y * 8, 8, 8, (px, py) {
          var c = _bgPixel(number, px, py);
          if (vramDotWidth == 3) c = bgTreatPlane23Zero ? c & 3 : (c & 3) << 2;
          return c == 0 ? 0 : rgba[colorTable[palette * 16 + c]];
        });
      }
    }
    canvas.viewport(scrollX, scrollY, hSize, vSize);
    if (map) return canvas.raster();
    return enableBg
        ? canvas.raster().cropWrapped(scrollX, scrollY, hSize, vSize)
        : DebugCanvas(hSize, vSize).raster();
  }

  DebugRaster _sprites(bool map) {
    final canvas = DebugCanvas(1024, 1024);
    if (map || enableSprite) {
      for (var n = 63; n >= 0; n--) {
        final sprite = Sprite.of(sat, n * 4);
        for (var ty = 0; ty < sprite.height ~/ 16; ty++) {
          for (var tx = 0; tx < sprite.width ~/ 16; tx++) {
            final number = sprite.patternNo + tx + ty * 2;
            canvas.tile(
                number,
                sprite.x +
                    (sprite.hFlip ? sprite.width - 16 - tx * 16 : tx * 16),
                sprite.y +
                    (sprite.vFlip ? sprite.height - 16 - ty * 16 : ty * 16),
                16,
                16, (x, y) {
              if (!map) {
                final sy = sprite.y +
                    (sprite.vFlip
                        ? sprite.height - 1 - ty * 16 - y
                        : ty * 16 + y);
                var earlier = 0;
                for (var i = 0; i < n; i++) {
                  final other = Sprite.of(sat, i * 4);
                  if (sy >= other.y && sy < other.y + other.height) earlier++;
                }
                if (earlier >= 16) return 0;
              }
              var c = _objPixel(number, x, y);
              if (vramDotWidth == 3) {
                final tile = sprite.patternNo + tx + ty * (sprite.width ~/ 16);
                final address = (tile * 32 + y) & 0xffff;
                c = ((vram[address] >> (15 - x)) & 1) |
                    ((vram[(address + 16) & 0xffff] >> (15 - x)) & 1) << 1;
                if (sprite.cgModeTreal01Zero) c <<= 2;
              }
              return c == 0 ? 0 : rgba[colorTable[sprite.paletteNo + c]];
            }, flipX: sprite.hFlip, flipY: sprite.vFlip);
          }
        }
      }
    }
    canvas.viewport(32, 64, hSize, vSize);
    return map
        ? canvas.raster()
        : canvas.raster().cropWrapped(32, 64, hSize, vSize);
  }
}
