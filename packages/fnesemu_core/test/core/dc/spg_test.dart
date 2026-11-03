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


}
