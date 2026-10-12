import 'dart:typed_data';

import 'package:fnesemu_core/app_api.dart';
import 'package:fnesemu_core/src/core/gb/gb.dart';
import 'package:fnesemu_core/src/core/gba/gba.dart';
import 'package:fnesemu_core/src/core/md/md.dart';
import 'package:fnesemu_core/src/core/n64/n64.dart';
import 'package:fnesemu_core/src/core/nes/mapper/mmc2.dart';
import 'package:fnesemu_core/src/core/nes/mapper/mmc3.dart';
import 'package:fnesemu_core/src/core/nes/nes.dart';
import 'package:fnesemu_core/src/core/pce/pce.dart';
import 'package:fnesemu_core/src/core/ps/ps.dart';
import 'package:fnesemu_core/src/core/snes/snes.dart';
import 'package:fnesemu_core/src/core/ss/ss.dart';
import 'package:fnesemu_core/src/video_debug.dart';
import 'package:test/test.dart';

int pixel(DebugRaster raster, int x, int y) =>
    ByteData.sublistView(raster.image.buffer)
        .getUint32((y * raster.image.width + x) * 4, Endian.little);

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
  test('shared pixel formats preserve bit-plane order and nibble order', () {
    final data = Uint8List(64);
    data[0] = 0x80;
    data[8] = 0x40;
    expect(debugPlanarPixel((a) => data[a], 0, 0, 0, [0, 8], rowStride: 1), 1);
    expect(debugPlanarPixel((a) => data[a], 0, 1, 0, [0, 8], rowStride: 1), 2);
    data[0] = 0x12;
    expect(debugPackedPixel((a) => data[a], 0, 0, 0), 2);
    expect(debugPackedPixel((a) => data[a], 0, 0, 0, highFirst: true), 1);
  });
  test('wrapped maps carry translated pattern numbers and split viewports', () {
    final map = DebugCanvas(16, 8);
    map.tile(10, 0, 0, 8, 8, (_, __) => 0xff0000ff);
    map.tile(11, 8, 0, 8, 8, (_, __) => 0xff00ff00);
    map.viewport(12, 0, 8, 8);
    final screen = map.raster().cropWrapped(12, 0, 8, 8);
    expect(pixel(screen, 0, 0), 0xff00ff00);
    expect(pixel(screen, 4, 0), 0xff0000ff);
    expect(map.viewports.length, 2);
    expect(screen.patterns.map((p) => p.label), containsAll(['A', 'B']));
  });
  test(
      'CPU notifications do not capture video; active views capture all sources',
      () {
    final core = _VideoCore(), debugger = Debugger(_VideoCore());
    final connected = Debugger(core)..setDebugView(true);
    connected.pushStream();
    expect(core.captures, 0);
    expect(core.samples, 0);
    connected.selectView(DebugView.layers);
    expect(connected.state.videoPanels.map((p) => p.name), ['BG', 'Sprites']);
    expect(core.captures, 2);
    connected.pushStream();
    expect(core.captures, 2);
    connected.setLayerView(LayerView.map);
    expect(connected.state.videoPanels.first.raster.image.width, 16);
    expect(connected.state.videoPanels.last.raster.image.width, 8);
    final before = connected.state;
    connected.setAlternativeBackground(true);
    expect(connected.state.videoPanels.first.background, 0xffabcdef);
    expect(before.videoPanels.first.background, 0xff123456);
    expect(debugger.state.videoPanels, isEmpty);
  });
  test(
      'live video follows frames only when enabled and only in the selected video view',
      () async {
    final core = _VideoCore(), debugger = Debugger(_VideoCore());
    debugger.setCore(core);
    debugger.setDebugView(true);
    debugger.selectView(DebugView.layers);
    final pausedCaptures = core.captures;
    debugger.pushStream(frameRendered: true);
    expect(core.captures, pausedCaptures);
    debugger.setVideoLive(true);
    final enabledCaptures = core.captures;
    debugger.pushStream();
    expect(core.captures, enabledCaptures);
    debugger.pushStream(frameRendered: true);
    expect(core.captures, enabledCaptures);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    debugger.pushStream(frameRendered: true);
    expect(core.captures, enabledCaptures + 2);
    debugger.selectView(DebugView.patterns);
    final inactiveLayerCaptures = core.captures;
    final samples = core.samples;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    debugger.pushStream(frameRendered: true);
    expect(core.samples, greaterThan(samples));
    expect(core.captures, inactiveLayerCaptures);
    debugger.setVideoLive(false);
    final stoppedSamples = core.samples;
    debugger.pushStream(frameRendered: true);
    expect(core.samples, stoppedSamples);
    debugger.setVideoLive(true);
    debugger.selectView(DebugView.cpu);
    final cpuSamples = core.samples, cpuCaptures = core.captures;
    debugger.pushStream(frameRendered: true);
    expect(core.samples, cpuSamples);
    expect(core.captures, cpuCaptures);
  });
  test(
      'pattern blocks group sequential tiles into 8, 16 or 32 pixel cells within 512 pixels',
      () {
    final table = DebugPatternTable('patterns',
        count: 256,
        colorCount: 256,
        transparentIndex: null,
        directColor: true,
        readPixel: (n, x, y) => 0xff000000 | n);
    for (final size in [8, 16, 32]) {
      final raster = table.capture(0, false, blockSize: size).raster;
      expect(raster.image.width, lessThanOrEqualTo(512));
      expect(pixel(raster, 0, 0), 0xff000000);
      expect(pixel(raster, 8, 0), 0xff000001);
      final tiles = size ~/ 8;
      if (tiles > 1) {
        expect(pixel(raster, 0, 8), 0xff000000 | tiles);
        expect(pixel(raster, size, 0), 0xff000000 | tiles * tiles);
      }
    }
  });

  test('palette cycling applies independently to all BG and OBJ tables', () {
    final debugger = Debugger(_VideoCore())
      ..setDebugView(true)
      ..selectView(DebugView.patterns);
    expect(debugger.state.videoPanels.map((p) => p.paletteName),
        ['Grayscale', 'Grayscale']);
    debugger.selectNextPalette();
    expect(debugger.state.videoPanels.map((p) => p.paletteName),
        ['Palette A', 'Palette A']);
    expect(pixel(debugger.state.videoPanels.first.raster, 0, 0),
        0); // transparency retained
    expect(pixel(debugger.state.videoPanels.first.raster, 1, 0), 0xff0000ff);
    debugger.selectNextPalette();
    expect(debugger.state.videoPanels.map((p) => p.paletteName),
        ['Palette B', 'Grayscale']);
    debugger.selectPreviousPalette();
    expect(debugger.state.videoPanels.map((p) => p.paletteName),
        ['Palette A', 'Palette A']);
    debugger.selectView(DebugView.layers);
    final screenColor = pixel(debugger.state.videoPanels.first.raster, 0, 0);
    debugger.selectNextPalette();
    expect(pixel(debugger.state.videoPanels.first.raster, 0, 0), screenColor);
  });

  test(
      'pattern contours follow shifted rows and distinguish equal pattern numbers',
      () {
    final regions = DebugPatternRegions(4, 3);
    for (var y = 0; y < 3; y++) {
      for (var x = 0; x < 4; x++)
        regions.mark(x, y, x < y + 1 ? 'left' : 'right', 7);
    }
    final outlines = regions.outlines();
    expect(outlines, hasLength(2));
    expect(outlines.every((shape) => shape.label == '7'), true);
    expect(outlines.first.points, contains((1.0, 1.0)));
    expect(outlines.first.points, contains((2.0, 2.0)));
  });
  test('affine pattern projection wraps and clips cells to the viewport', () {
    final map = DebugCanvas(8, 8)..tile(3, 0, 0, 8, 8, (_, __) => 0);
    final screen = DebugCanvas(8, 8)
      ..projectPatterns(map.raster(), const DebugAffine(1, 0, 0, 1, 4, 0),
          wrap: true);
    expect(screen.patterns, hasLength(2));
    expect(
        screen.patterns
            .expand((shape) => shape.points)
            .every((p) => p.$1 >= 0 && p.$1 <= 8 && p.$2 >= 0 && p.$2 <= 8),
        true);
  });
  test(
      'GB maps decode the current pattern and palette without touching the framebuffer',
      () {
    final core = Gb();
    core.ppu.vram[0] = 0x80;
    core.ppu.bgp = 0xe4;
    core.ppu.lcdc = 0x91;
    final before = Uint8List.fromList(core.imageBuffer().buffer);
    final raster = core.videoLayers.first.capture(true);
    expect(pixel(raster, 0, 0), 0xff70c088);
    expect(pixel(raster, 1, 0), 0xffd0f8e0);
    expect(core.imageBuffer().buffer, orderedEquals(before));
  });
  test(
      'GBA layer reads current VRAM, uses its palette and hides disabled layers',
      () {
    final core = Gba();
    core.bus.write16(0x04000000, 0x0100);
    core.bus.write16(0x04000008, 4);
    core.bus.vram[0x4000] = 1;
    core.bus.write16(0x05000002, 31);
    final raster = core.videoLayers.first.capture(false);
    expect(pixel(raster, 0, 0), 0xff0000ff);
    expect(raster.patterns.first.label, '0');
    core.bus.write16(0x04000000, 0);
    expect(core.videoLayers.first.capture(false).patterns, isEmpty);
  });
  test(
      'SNES BG uses the current CGRAM and separates 16 pixel cells into actual subpatterns',
      () {
    final core = Snes();
    core.ppu.bgMode = 0;
    core.ppu.forcedBlank = false;
    core.ppu.mainScreenEnable = 1;
    core.ppu.bgs[0].charBase = 0x1000;
    core.ppu.bgs[0].bigChar = true;
    core.ppu.vram[0x2000] = 0x80;
    core.ppu.cgram[2] = 31;
    final raster = core.videoLayers.first.capture(true);
    expect(pixel(raster, 0, 0), 0xff0000ff);
    expect(raster.patterns.map((p) => p.label),
        containsAll(['0', '1', '10', '11']));
  });

  test('SS owns the two NBG rows, rotation row and sprite row', () {
    final core = Ss();
    expect(core.videoLayers.map((layer) => layer.row), [0, 0, 1, 1, 2, 3]);
    core.vdp2.writeReg(0xb0, 2);
    expect(core.videoLayers.map((layer) => layer.row), [0, 0, 1, 1, 2, 2, 3]);
  });

  test('SNES pattern tables pair BG1/BG2 and BG3/BG4 by row', () {
    final core = Snes();
    core.ppu.bgMode = 0;
    final backgrounds = core.patternTables
        .where((table) => table.kind == DebugLayerKind.background)
        .toList();
    expect(backgrounds.map((table) => table.row), [0, 0, 1, 1]);
    expect(
        backgrounds.map((table) => table.capture(0, false).row), [0, 0, 1, 1]);
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
    test('${entry.key} exposes isolated layers and valid pattern readers', () {
      final core = entry.value()..setSram(Sram());
      final before = Uint8List.fromList(core.imageBuffer().buffer);
      expect(core.videoLayers, isNotEmpty);
      for (final layer in core.videoLayers) {
        final image = layer.capture(false);
        expect(image.image.buffer.length,
            image.image.width * image.image.height * 4,
            reason: layer.name);
      }
      expect(core.imageBuffer().buffer, orderedEquals(before));
      if (entry.key == 'ps' || entry.key == 'n64') {
        expect(core.patternTables, isEmpty);
      } else {
        expect(core.hasPatternTables, true);
        expect(core.patternTables, isNotEmpty);
        for (final table in core.patternTables) {
          expect(table.readPixel(0, 0, 0), isA<int>());
          expect(
              table.readPixel(
                  table.count - 1, table.width - 1, table.height - 1),
              isA<int>());
        }
      }
    });
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
  test('GBA affine reference latches are unchanged by debugging', () {
    final core = Gba();
    core.bus.affineRefDirty[0] = true;
    core.videoLayers.first.capture(false);
    expect(core.bus.affineRefDirty[0], true);
  });
}
