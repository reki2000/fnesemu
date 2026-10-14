// Synthetic debug capture benchmark; no ROMs or GUI required.
// dart run tool/video_debug_bench.dart [core ...]
// Reports the median of seven captures after three warmups. Checksums cover
// pixels and annotations; compare them when assessing an optimization.
import 'dart:convert';
import 'dart:io';

import 'package:fnesemu_core/app_api.dart';
import 'package:fnesemu_core/src/core/gb/gb.dart';
import 'package:fnesemu_core/src/core/gba/gba.dart';
import 'package:fnesemu_core/src/core/md/md.dart';
import 'package:fnesemu_core/src/core/n64/n64.dart';
import 'package:fnesemu_core/src/core/nes/nes.dart';
import 'package:fnesemu_core/src/core/pce/pce.dart';
import 'package:fnesemu_core/src/core/ps/ps.dart';
import 'package:fnesemu_core/src/core/snes/snes.dart';
import 'package:fnesemu_core/src/core/ss/ss.dart';

void main(List<String> args) {
  final cores = <String, Core>{
    'nes': Nes(),
    'gb': Gb(),
    'gba': Gba(),
    'md': Md(),
    'pce': Pce(),
    'snes': Snes(),
    'ss': Ss(),
    'ps': Ps(),
    'n64': N64(),
  };
  void fill(List<int> bytes) {
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = (i * 13 + (i >> 8)) & 255;
    }
  }

  final nes = cores['nes'] as Nes;
  nes.ppu.ctl2 = 0x1e;
  fill(nes.ppu.objRam);
  final gb = cores['gb'] as Gb;
  gb.ppu.lcdc = 0xf7;
  gb.ppu.bgp = gb.ppu.obp0 = gb.ppu.obp1 = 0xe4;
  fill(gb.ppu.vram);
  fill(gb.ppu.oam);
  final pce = cores['pce'] as Pce;
  pce.reset();
  pce.vdc.enableBg = pce.vdc.enableSprite = true;
  for (var n = 0; n < 64; n++) {
    pce.vdc.sat[n * 4] = 64 + n % 4;
    pce.vdc.sat[n * 4 + 1] = 32 + n * 3;
    pce.vdc.sat[n * 4 + 2] = n * 8;
    pce.vdc.sat[n * 4 + 3] = 0x3180 | (n & 15);
  }
  final gba = cores['gba'] as Gba;
  gba.bus.write16(0x04000000, 0x1f00);
  fill(gba.bus.vram);
  fill(gba.bus.oam);
  final snes = cores['snes'] as Snes;
  snes.ppu.bgMode = 0;
  snes.ppu.forcedBlank = false;
  snes.ppu.mainScreenEnable = 0x1f;
  fill(snes.ppu.vram);
  fill(snes.ppu.oam);
  final md = cores['md'] as Md;
  md.vdp.reg[1] = 0x40;
  fill(md.vdp.vram);
  final ss = cores['ss'] as Ss;
  ss.vdp2.writeReg(0, 0x8000);
  ss.vdp2.writeReg(0x20, 0x1f);
  fill(ss.vdp2.vram);
  for (final entry in cores.entries) {
    if (args.isNotEmpty && !args.contains(entry.key)) continue;
    entry.value.setSram(Sram());
    for (final view in ['viewport', 'map', 'patterns']) {
      List<DebugRaster> capture() => view == 'patterns'
          ? [
              for (final t in entry.value.patternTables)
                t.capture(1, false).raster
            ]
          : [
              for (final l in entry.value.videoLayers)
                l.capture(view == 'map' && l.hasMap)
            ];
      final reference = capture();
      var hash = 0x811c9dc5;
      void mix(Iterable<int> bytes) {
        for (final byte in bytes) {
          hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
        }
      }

      for (final r in reference) {
        mix(r.image.buffer);
        mix(utf8.encode(jsonEncode([
          r.image.width,
          r.image.height,
          for (final shapes in [r.patterns, r.viewports])
            [
              for (final s in shapes)
                [
                  s.label,
                  for (final p in s.points) [p.$1, p.$2]
                ]
            ]
        ])));
      }
      for (var n = 0; n < 3; n++) {
        capture();
      }
      final times = <int>[];
      for (var n = 0; n < 7; n++) {
        final watch = Stopwatch()..start();
        capture();
        watch.stop();
        times.add(watch.elapsedMicroseconds);
      }
      times.sort();
      stdout.writeln(
          '${entry.key} $view ${(times[times.length ~/ 2] / 1000).toStringAsFixed(2)}ms ${hash.toRadixString(16)}');
    }
  }
}
