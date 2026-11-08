import 'dart:math';
import 'dart:typed_data';

import 'package:fnesemu_core/app_api.dart';
import 'package:fnesemu_core/src/core/gb/gb.dart';
import 'package:fnesemu_core/src/core/gba/gba.dart';
import 'package:fnesemu_core/src/core/md/md.dart';
import 'package:fnesemu_core/src/core/n64/n64.dart';
import 'package:fnesemu_core/src/core/nes/mapper/mmc2.dart';
import 'package:fnesemu_core/src/core/nes/mapper/mmc3.dart';
import 'package:fnesemu_core/src/core/nes/nes.dart';
import 'package:fnesemu_core/src/core/pce/component/vdc_render.dart';
import 'package:fnesemu_core/src/core/pce/pce.dart';
import 'package:fnesemu_core/src/core/ps/ps.dart';
import 'package:fnesemu_core/src/core/snes/snes.dart';
import 'package:fnesemu_core/src/core/ss/ss.dart';
import 'package:fnesemu_core/src/video_debug.dart';
import 'package:test/test.dart';

int pixel(DebugRaster raster, int x, int y) =>
    raster.image.buffer[y * raster.image.width + x];

class _VideoCore extends CoreDebug {
  int captures = 0, samples = 0;
  @override
  List<CpuInfo> get cpuInfos => const [CpuInfo(0, 'CPU', 16)];
  @override
  bool get hasPatternTables => true;
  @override
  List<DebugVideoLayer> get videoLayers => [
        DebugVideoLayer('BG', (map) {
          captures++;
          final c = DebugCanvas(map ? 16 : 8, 8);
          c.tile(4, 0, 0, 8, 8, (_, __) => 0xff0000ff);
          c.viewport(0, 0, 8, 8);
          return c.raster();
        },
            hasMap: true,
            originalBackground: 0xff123456,
            alternativeBackground: 0xffabcdef),
        DebugVideoLayer('Sprites', (_) {
          captures++;
          return DebugCanvas(8, 8).raster();
        }),
      ];
  @override
  List<DebugPatternTable> get patternTables => [
        for (var n = 0; n < 2; n++)
          DebugPatternTable(n == 0 ? 'BG patterns' : 'Sprite patterns',
              count: 1, colorCount: 4, readPixel: (_, x, y) {
            samples++;
            return x == 0 ? 0 : 1;
          }, palettes: [
            DebugPalette(
                'Palette A', [0xff000000, 0xff0000ff, 0xff00ff00, 0xffff0000]),
            if (n == 0)
              DebugPalette(
                  'Palette B', [0xff000000, 0xff00ff00, 0xffff0000, 0xff0000ff])
          ]),
      ];
}

void main() {

  test(
      'GB maps decode the current pattern and palette without touching the framebuffer',
      () {
    final core = Gb();
    core.ppu.vram[0] = 0x80;
    core.ppu.bgp = 0xe4;
    core.ppu.lcdc = 0x91;
    final before = Uint32List.fromList(core.imageBuffer().buffer);
    final raster = core.videoLayers.first.capture(true);
    expect(pixel(raster, 0, 0), 0xff70c088);
    expect(pixel(raster, 1, 0), 0xffd0f8e0);
    expect(core.imageBuffer().buffer, orderedEquals(before));
  });

  final constructors = <String, Core Function()>{
    'nes': Nes.new,
    'gb': Gb.new,
    'gba': Gba.new,
    'md': Md.new,
    'pce': Pce.new,
    'snes': Snes.new,
    'ss': Ss.new,
    'ps': Ps.new,
    'n64': N64.new
  };
  for (final entry in constructors.entries) {
  }
  test('NES map capture does not clock MMC3 IRQs or change MMC2 latches', () {
    final core = Nes();
    final mapper = MapperMMC3();
    mapper.setRom(Uint8List(0x2000), Uint8List(0x8000));
    mapper.init();
    int irqChanges = 0;
    mapper.holdIrq = (_) => irqChanges++;
    mapper.write(0xc000, 0);
    mapper.write(0xe001, 0);
    core.bus.mapper = mapper;
    core.videoLayers.first.capture(true);
    core.patternTables.first.capture(1, false);
    expect(irqChanges, 0);
    final latch = MapperMMC2();
    latch.setRom(
        Uint8List.fromList([for (var i = 0; i < 0x20000; i++) i ~/ 0x1000]),
        Uint8List(0x8000));
    latch.init();
    latch.write(0xb000, 1);
    latch.write(0xc000, 2);
    core.bus.mapper = latch;
    final state = latch.peekVram(0);
    core.patternTables.first.capture(1, false);
    expect(latch.peekVram(0), state);
  });
}
