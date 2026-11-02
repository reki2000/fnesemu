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
    test('MD mode $mode retains alternating output rows at normal display height', () {
      final vdp = Vdp()
        ..trackOpacity = true
        ..write16(4, 0x8c00 | mode << 1);
      vdp.cram[0] = 0x007;
      vdp.vCounter = 1;
      vdp.renderLine();
      final first = vdp.buffer[0];
      vdp.oddFrame = true;
      vdp.cram[0] = 0x1c0;
      vdp.vCounter = 1;
      vdp.renderLine();
      final image = vdp.imageBuffer;
      expect((image.height, image.displayHeight), (448, 224));
      expect(image.buffer[0], first);
      expect(image.buffer[image.width], isNot(first));
      final writer = StateWriter('md-field', 1, 0);
      vdp.saveState(writer);
      final restored = Vdp();
      final reader = StateReader(writer.take(), 'md-field', 1, 0);
      restored.loadState(reader);
      reader.end();
      expect(restored.imageBuffer.height, image.height);
      expect(restored.buffer, vdp.buffer);
      expect(restored.opaque, vdp.opaque);
      vdp.write16(4, 0x8c00);
      expect(vdp.imageBuffer.height, 224);
      vdp.write16(4, 0x8c06);
      vdp.reset();
      expect(vdp.imageBuffer.height, 224);
    });
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

  test('SNES interlaced BG and OBJ fetch distinct rows in alternate fields', () {
    for (final sprites in [false, true]) {
      final core = Snes();
      final ppu = core.ppu;
      ppu.write(0x2100, 0x0f);
      ppu.write(0x2105, sprites ? 0 : 5);
      ppu.write(0x212c, sprites ? 0x10 : 1);
      ppu.write(0x2133, sprites ? 3 : 1);
      ppu.bgs[0].tilemapAddr = 0x1000;
      final paletteBase = sprites ? 128 : 0;
      ppu.cgram[(paletteBase + 1) * 2] = 0x1f;
      ppu.cgram[(paletteBase + 2) * 2 + 1] = 0x7c;
      final firstRow = sprites ? 0 : 2;
      ppu.vram[firstRow * 2] = 0xff;
      ppu.vram[(firstRow + 1) * 2 + 1] = 0xff;
      ppu.renderScanline(1);
      ppu.oddField = true;
      ppu.renderScanline(1);
      final image = core.imageBuffer();
      expect(image.height, 448);
      expect(image.displayHeight, 224);
      expect(image.buffer[0], 0xff0000ff);
      expect(image.buffer[image.width], 0xffff0000);
    }
  });

  for (final mode in [1, 3]) {
    test('SS mode $mode retains alternate rows with unchanged display height', () {
      final ss = Ss(cpuFactory: (bus, master) => NullCpu(bus, master: master))
        ..setSram(Sram())
        ..setRom(Uint8List(0x80000))
        ..reset();
      addTearDown(ss.dispose);
      ss.vdp2.writeReg(0, mode << 6);
      ss.runFrame(ss.scanlinesInFrame);
      final first = ss.imageBuffer();
      expect((first.height, first.displayHeight), (448, 224));
      expect(first.buffer[0], 0xff000000);
      first.buffer.fillRange(0, first.buffer.length, 0xff123456);
      ss.runFrame(ss.scanlinesInFrame);
      final second = ss.imageBuffer();
      expect(second.buffer[0], 0xff123456);
      expect(second.buffer[second.width], 0xff000000);
    });
  }

  test('N64 latches source rows and exposes alternating VI field parity', () {
    final bus = N64Bus();
    bus.vi[0] = 0x42;
    bus.vi[1] = 0x100;
    bus.vi[2] = 1;
    bus.vi[9] = 2;
    bus.vi[10] = 4;
    bus.vi[12] = 512;
    bus.vi[13] = 2048;
    for (final entry in [(0, 0xf801), (2, 0x07c1), (4, 0x003f), (6, 0xffff)]) {
      bus.write(0xa0000100 + entry.$1, entry.$2, 2);
    }
    bus.finishVideoField();
    final first = bus.image();
    final firstPixels = List<int>.of(first.buffer);
    expect((first.height, first.displayHeight), (4, 2));
    expect(first.buffer, [0xff0000ff, 0xff000000, 0xffff0000, 0xff000000]);
    expect(bus.read(0xa4400010, 4) & 1, 1);
    final writer = StateWriter('vi-field', 1, 0);
    bus.saveState(writer);
    final restored = N64Bus();
    final reader = StateReader(writer.take(), 'vi-field', 1, 0);
    restored.loadState(reader);
    reader.end();
    expect(restored.image().buffer, first.buffer);
    restored.vi[1] += 2;
    restored.finishVideoField();
    expect(restored.image().buffer,
        [0xff0000ff, 0xff00ff00, 0xffff0000, 0xffffffff]);
    bus.vi[1] += 2;
    expect(bus.image().buffer, first.buffer);
    bus.finishVideoField();
    expect(bus.image().buffer, [0xff0000ff, 0xff00ff00, 0xffff0000, 0xffffffff]);
    expect(bus.image().buffer, same(first.buffer));
    expect(firstPixels[1], 0xff000000);
    expect(bus.read(0xa4400010, 4) & 1, 0);
    bus.write(0xa4400000, 2, 4);
    expect(bus.image().height, 4);
  });

  for (final mode in [1, 3]) {
    test('PS2 mode $mode latches one field without duplicating the current field', () {
      final gs = Gs();
      gs.writePrivileged(0x12000000, 1);
      gs.writePrivileged(0x12000020, mode);
      gs.writePrivileged(0x12000070, 1 << 9);
      gs.writePrivileged(0x12000080, 3 << 44); // One pixel, four output rows.
      for (var y = 0; y < 4; y++) {
        gs.mem.write(GsPsm.ct32, 0, 1, 0, y, y + 1);
      }
      gs.vblank();
      final first = gs.image();
      final firstPixels = List<int>.of(first.buffer);
      expect((first.height, first.displayHeight), (4, 2));
      expect(first.buffer, [0xff000001, 0xff000000, mode == 1 ? 0xff000003 : 0xff000002, 0xff000000]);
      for (var y = 0; y < 4; y++) {
        gs.mem.write(GsPsm.ct32, 0, 1, 0, y, y + 11);
      }
      expect(gs.image().buffer, first.buffer);
      gs.vblank();
      final second = gs.image();
      expect(second.buffer, same(first.buffer));
      expect(second.buffer[0], firstPixels[0]);
      expect(second.buffer[2], firstPixels[2]);
      expect(second.buffer[1], mode == 1 ? 0xff00000c : 0xff00000b);
      expect(second.buffer[3], mode == 1 ? 0xff00000e : 0xff00000c);
      final writer = StateWriter('gs-field', 1, 0);
      gs.saveState(writer);
      final restored = Gs();
      final reader = StateReader(writer.take(), 'gs-field', 1, 0);
      restored.loadState(reader);
      reader.end();
      expect(restored.image().buffer, second.buffer);
      gs.vblank();
      restored.vblank();
      expect(restored.image().buffer, gs.image().buffer);
      gs.reset();
      expect(gs.image().buffer[1], 0xff000000);
    });
  }

  test('field writes reuse storage and leave the other parity untouched', () {
    final output = FieldOutput();
    final first = output.writeField(
        ImageBuffer(1, 1, Uint32List.fromList([0xff123456])), 0);
    final second = output.writeField(
        ImageBuffer(1, 1, Uint32List.fromList([0xffabcdef])), 1);
    expect(second, same(first));
    expect(second.buffer, same(first.buffer));
    expect(second.buffer, [0xff123456, 0xffabcdef]);
    final resized = output.writeField(
        ImageBuffer(2, 1, Uint32List.fromList([0xff111111, 0xff222222])), 0);
    expect(resized.buffer, isNot(same(second.buffer)));
    expect(resized.buffer, [0xff111111, 0xff222222, 0xff000000, 0xff000000]);
  });

  test('field output state preserves the previous field and display metadata', () {
    final output = FieldOutput();
    output.writeField(ImageBuffer(1, 1, Uint32List.fromList([0xff123456]),
        displayWidth_: 2, displayHeight: 1), 0);
    final writer = StateWriter('field-test', 1, 0);
    output.saveState(writer);
    final restored = FieldOutput();
    final reader = StateReader(writer.take(), 'field-test', 1, 0);
    restored.loadState(reader);
    reader.end();
    final image = restored.writeField(ImageBuffer(1, 1, Uint32List.fromList([0xffabcdef]),
        displayWidth_: 2, displayHeight: 1), 1);
    expect(image.buffer, [0xff123456, 0xffabcdef]);
    expect((image.displayWidth, image.displayHeight), (2, 1));
    output.reset();
    expect(output.image, isNull);
  });
}
