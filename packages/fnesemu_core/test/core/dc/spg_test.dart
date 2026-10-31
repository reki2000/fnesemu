import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/spg.dart';
import 'package:test/test.dart';

void main() {
  late DcBus bus;
  const base = 0xa05f8000;
  setUp(() => bus = DcBus());
  void tiny(DcBus bus, {bool interlace = false, bool fast = true}) {
    bus.write32(base + 0x44, fast ? 0x800000 : 0);
    bus.write32(base + 0xd8, 0x00020008); // Nine clocks, three scanlines.
    bus.write32(
        base + 0xc8, 0x00042000); // HBlank IRQ at pixel four, every line.
    bus.write32(base + 0xcc, 0x00020001); // In at line one, out at line two.
    bus.write32(base + 0xd4, 0x00020006);
    bus.write32(base + 0xdc, 0x00000002);
    bus.write32(base + 0xe0, 0x00000101);
    bus.write32(base + 0xec, 2);
    bus.write32(base + 0xf0, 0);
    bus.write32(base + 0xd0, interlace ? 0x110 : 0x100);
  }

  test('SPG reset registers, widths, reserved fields and unsupported modes',
      () {
    expect(bus.read32(base + 0xd0), 0x40);
    expect(bus.read32(base + 0xd8), 0x01060359);
    expect(bus.read32(base + 0xc8), 0x031d0000);
    expect(bus.read32(base + 0xcc), 0x01500104);
    expect(bus.read32(base + 0x10c), 0);
    expect(() => bus.read16(base + 0xd8), throwsA(isA<DcUnsupported>()));
    expect(
        () => bus.write32(base + 0xc8, 0x3000), throwsA(isA<DcUnsupported>()));
    expect(
        () => bus.write32(base + 0xc8, 0x1000), throwsA(isA<DcUnsupported>()));
    expect(
        () => bus.write32(base + 0xd0, 0x108), throwsA(isA<DcUnsupported>()));
    expect(bus.read32(base + 0xd0), 0x40);
    bus.write32(base + 0xd8, 0xffffffff);
    expect(bus.read32(base + 0xd8), 0x03ff03ff);
  });

  test('fractional 27 MHz progression crosses exact line and field boundaries',
      () {
    tiny(bus);
    bus.tickMasterClocks(66);
    expect(bus.gpu.spg.completedLines, 0);
    bus.tickMasterClocks(1);
    expect(bus.gpu.spg.completedLines, 1);
    expect(bus.gpu.spg.scanline, 1);
    bus.tickMasterClocks(133);
    expect(bus.gpu.spg.completedLines, 3);
    expect(bus.gpu.spg.completedFields, 1);
    expect(bus.gpu.spg.scanline, 0);
    expect(bus.read32(0xa05f6900) & 0x38, 0x38);
  });

  test(
      '13.5 MHz mode doubles the duration and external sync pauses progression',
      () {
    tiny(bus, fast: false);
    bus.tickMasterClocks(399);
    expect(bus.gpu.spg.completedFields, 0);
    bus.tickMasterClocks(1);
    expect(bus.gpu.spg.completedFields, 1);
    bus.write32(base + 0xd0, 0);
    bus.tickMasterClocks(4000);
    expect(bus.gpu.spg.completedFields, 1);
  });

  test('HBlank/VBlank and sync flags follow counter edges; trigger latches HV',
      () {
    tiny(bus);
    bus.tickMasterClocks(45); // Six pixel clocks.
    expect(bus.read32(base + 0x10c) & 0x800, 0x800);
    bus.gpu.spg.latchExternalTrigger();
    expect(bus.read32(base + 0xc4), 6);
    bus.tickMasterClocks(37); // Eleven total clocks: line 1, pixel 2.
    expect(bus.read32(base + 0x10c) & 0x801, 1);
    expect(bus.read32(base + 0x10c) & 0x3000, 0);
    bus.tickMasterClocks(52); // Line 2, pixel 0: vertical blank starts.
    expect(bus.read32(base + 0x10c) & 0x800, 0x800);
    bus.tickMasterClocks(66);
    expect(bus.read32(base + 0x10c) & 0x800,
        0x800); // HBlank crosses the line boundary.
    bus.tickMasterClocks(15);
    expect(bus.read32(base + 0x10c) & 0x800, 0);
    expect(bus.read32(base + 0xc4), 6);
  });

  for (final mode in [0, 1, 2]) {
    test('HBlank interrupt mode $mode handles selected/every-N/every lines',
        () {
      final spg = DcSpg();
      var count = 0;
      spg.onInterrupt = (sources) {
        if (sources & 32 != 0) count++;
      };
      spg.setFastClock(true);
      spg.write(0xd8, 0x00050008); // Six lines per field.
      spg.write(0xc8, 0x00040002 | (mode << 12));
      spg.write(0xd0, 0x100);
      spg.tickMasterClocks(400); // 54 clocks = one field.
      expect(count, [1, 3, 6][mode]);
    });
  }

  test('HOLLY receives SPG sources and SH4 accepts a configured VBlank IRQ',
      () {
    final core = Dc()..setRom(Uint8List.fromList([0xfe, 0xaf, 9, 0]));
    tiny(core.bus);
    core.cpu.sr = 0x40000000;
    core.cpu.vbr = 0x8c030000;
    core.bus.write32(0xa05f6930, 8);
    core.bus.tickMasterClocks(67);
    expect(core.cpu.irlPins, 9);
    expect(core.exec(true).executed(0), isFalse);
    expect(core.bus.intevt, 0x320);
  });

  test('Core reports actual line crossings and uses configured field length',
      () {
    final core = Dc(jit: false)..setRom(Uint8List.fromList([0xfe, 0xaf, 9, 0]));
    tiny(core.bus);
    core.bus.write32(base + 0x44, 0x80000d);
    core.bus.write32(base + 0xe8, 0);
    core.bus.write32(base + 0x5c, 1 << 20);
    core.bus.write32(0xa5000000, 0x00112233);
    expect(core.clocksInScanline, 67);
    expect(core.scanlinesInFrame, 3);
    core.runFrame(1);
    expect(core.cpuClocks, 67);
    expect(core.imageBuffer().buffer, isEmpty);
    core.runFrame(2);
    expect(core.cpuClocks, 200);
    expect(core.bus.gpu.spg.completedFields, 1);
    expect(core.imageBuffer().buffer, [0xff332211]);
  });

  test(
      'field-end snapshots latch page flips for the next field and remain immutable',
      () {
    tiny(bus);
    bus.write32(base + 0xe8, 0);
    bus.write32(base + 0x44, 0x80000d);
    bus.write32(base + 0x5c, 1 << 20);
    bus.write32(0xa5000000, 0x00112233);
    bus.write32(0xa5000004, 0x00445566);
    bus.write32(base + 0x50, 4);
    bus.tickMasterClocks(200);
    final first = bus.gpu.presentedImage;
    expect(first.buffer, [0xff332211]);
    expect(bus.read32(base + 0x114), 4);
    bus.write32(base + 0x114, 0);
    expect(bus.read32(base + 0x114), 4);
    bus.tickMasterClocks(200);
    expect(bus.gpu.presentedImage.buffer, [0xff665544]);
    expect(first.buffer, [0xff332211]);
    bus.write32(0xa5000004, 0x00778899);
    expect(bus.gpu.presentedImage.buffer, [0xff665544]);
    bus.tickMasterClocks(200);
    expect(bus.gpu.presentedImage.buffer, [0xff998877]);
  });

  test(
      'interlaced half-line counters alternate and weave both framebuffer fields',
      () {
    tiny(bus, interlace: true, fast: false);
    bus.write32(base + 0xe8, 0);
    bus.write32(base + 0x44, 0xd);
    bus.write32(base + 0x5c, 1 << 20);
    bus.write32(base + 0x54, 4);
    bus.write32(0xa5000000, 0x00112233);
    bus.write32(0xa5000004, 0x00445566);
    bus.tickMasterClocks(200);
    expect(bus.gpu.spg.field2, isTrue);
    expect(bus.read32(base + 0x10c) & 0x400, 0x400);
    expect(bus.gpu.presentedImage.buffer, [0xff332211, 0xff000000]);
    bus.tickMasterClocks(200);
    expect(bus.gpu.spg.field2, isFalse);
    expect(bus.gpu.presentedImage.buffer, [0xff332211, 0xff665544]);
    expect(bus.gpu.presentedImage.height, 2);
  });

  test('batched clocks preserve all counter/IRQ state and rational remainder',
      () {
    tiny(bus);
    final single = DcBus();
    tiny(single);
    bus.tickMasterClocks(10003);
    for (var i = 0; i < 10003; i++) {
      single.tickMasterClocks(1);
    }
    expect(bus.gpu.spg.completedFields, single.gpu.spg.completedFields);
    expect(bus.gpu.spg.completedLines, single.gpu.spg.completedLines);
    expect(bus.read32(base + 0x10c), single.read32(base + 0x10c));
    expect(bus.read32(0xa05f6900), single.read32(0xa05f6900));
    bus.tickMasterClocks(197);
    single.tickMasterClocks(197);
    expect(bus.gpu.spg.completedFields, 51);
    expect(bus.read32(base + 0x10c), single.read32(base + 0x10c));
  });

  test('VRAM DMA interleaves before later video snapshots in a clock batch',
      () {
    final single = DcBus();
    for (final target in [bus, single]) {
      tiny(target);
      target.write32(base + 0xe8, 0);
      target.write32(base + 0x44, 0x80000d);
      target.write32(base + 0x5c, 1 << 20);
      for (var i = 0; i < 120; i++) {
        target.write32(0xac020000 + i * 4, i + 1);
      }
      target.write32(0xffa00000, 0x0c020000);
      target.write32(0xffa00004, 0x05000000);
      target.write32(0xffa00008, 120);
      target.write32(0xffa0000c, 0x5431);
      target.write32(0xffa00040, 1);
    }
    bus.tickMasterClocks(400);
    for (var i = 0; i < 400; i++) {
      single.tickMasterClocks(1);
    }
    expect(bus.gpu.presentedImage.buffer, single.gpu.presentedImage.buffer);
    expect(bus.gpu.presentedImage.buffer, [0xff010000]);
    expect(bus.read32(0xffa00008), 0);
  });
  for (final (name, load, control, fast, ticks) in [
    ('NTSC progressive', 0x01060359, 0x140, false, 3343023),
    ('NTSC interlaced', 0x020c0359, 0x150, false, 3336667),
    ('PAL progressive', 0x0138035f, 0x180, false, 4006400),
    ('PAL interlaced', 0x0270035f, 0x190, false, 4000000),
    ('VGA', 0x020c0359, 0x100, true, 3336667),
  ]) {
    test(
        'official $name preset reaches its first field at the nominal deadline',
        () {
      final spg = DcSpg();
      spg.setFastClock(fast);
      spg.write(0xd8, load);
      spg.write(0xd0, control);
      spg.tickMasterClocks(ticks - 1);
      expect(spg.completedFields, 0);
      spg.tickMasterClocks(1);
      expect(spg.completedFields, 1);
      expect(spg.scanline, 0);
    });
  }

  test('video continues while CPG pauses SH4 clocks for PLL stabilization', () {
    final core = Dc()..setRom(Uint8List.fromList([9, 0]));
    tiny(core.bus);
    core.bus.write16(0xffc00008, 0x5af0);
    core.bus.write16(0xffc00000, 0xe13);
    final result = core.runFrame(3);
    expect(result.executed(0), isFalse);
    expect(result.elapsedClocks, 512);
    expect(core.bus.gpu.spg.completedFields, 2);
    expect(result.scanlineRendered, isTrue);
  });
}
