import 'dart:typed_data';

import 'package:fnesemu_core/src/core/md/vdp.dart';
import 'package:fnesemu_core/src/core/md/vdp_renderer.dart';
import 'package:fnesemu_core/src/core/n64/bus.dart';
import 'package:fnesemu_core/src/core/ps2/gs/gs.dart';
import 'package:fnesemu_core/src/core/ps2/gs/gs_memory.dart';
import 'package:fnesemu_core/src/core/snes/component/ppu_render.dart';
import 'package:fnesemu_core/src/core/snes/snes.dart';
import 'package:fnesemu_core/src/core/ss/cpu.dart';
import 'package:fnesemu_core/src/core/ss/ss.dart';
import 'package:fnesemu_core/src/field_output.dart';
import 'package:fnesemu_core/src/sram.dart';
import 'package:fnesemu_core/src/state.dart';
import 'package:fnesemu_core/src/types.dart';
import 'package:test/test.dart';

void main() {
  for (final mode in [1, 3]) {
  }

  test('SNES retains fields, reports field parity and keeps the display size', () {
    final core = Snes();
    final ppu = core.ppu;
    ppu.write(0x2133, 1);
    ppu.write(0x2100, 0x0f);
    ppu.cgram[0] = 0x1f;
    ppu.renderScanline(1);
    final first = ppu.buffer[0];
    ppu.oddField = true;
    ppu.cgram[0] = 0;
    ppu.cgram[1] = 0x7c;
    ppu.renderScanline(1);
    final image = core.imageBuffer();
    expect((image.height, image.displayHeight), (448, 224));
    expect(image.buffer[0], first);
    expect(image.buffer[image.width], isNot(first));
    expect(ppu.read(0x213f) & 0x80, 0x80);
    ppu.write(0x2133, 5);
    expect((core.imageBuffer().height, core.imageBuffer().displayHeight), (478, 239));
    ppu.reset();
    expect((core.imageBuffer().height, ppu.oddField), (224, false));
  });

  for (final mode in [1, 3]) {
  }

  for (final mode in [1, 3]) {
  }

}
