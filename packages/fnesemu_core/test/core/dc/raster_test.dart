import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:test/test.dart';

void main() {
  const base = 0xa05f8000;
  late DcBus bus;
  setUp(() => bus = DcBus());

  void configure(DcBus bus,
      {int width = 2,
      int height = 3,
      bool interlace = false,
      bool doubleLine = false}) {
    bus.write32(base + 8, 0);
    bus.write32(base + 0x44, 0x80000d | (doubleLine ? 2 : 0));
    bus.write32(base + 0x5c, (width - 1) | ((height - 1) << 10) | (1 << 20));
    bus.write32(base + 0xe8, 0);
    bus.write32(base + 0xec, 2);
    bus.write32(base + 0xf0, 0);
    bus.write32(base + 0xd8, 0x00050008); // Nine pixels, six counter lines.
    bus.write32(base + 0xd4, 0x00010008);
    bus.write32(base + 0xdc, 0x00000005);
    bus.write32(base + 0xd0, interlace ? 0x110 : 0x100);
  }

  test('display-start registers reset and mask reserved bits', () {
    expect(bus.read32(base + 0xec), 0x9d);
    expect(bus.read32(base + 0xf0), 0x00150015);
    bus.write32(base + 0xec, 0xffffffff);
    bus.write32(base + 0xf0, 0xffffffff);
    expect(bus.read32(base + 0xec), 1023);
    expect(bus.read32(base + 0xf0), 0x03ff03ff);
  });

  test('past rows retain old pixels while not-yet-scanned rows see new VRAM',
      () {
    configure(bus, width: 1);
    bus.write32(0xa5000000, 0x00112233);
    bus.write32(0xa5000004, 0x00445566);
    bus.write32(0xa5000008, 0x00778899);
    bus.tickMasterClocks(15); // Line zero has reached display pixel two.
    expect(bus.gpu.presentedImage.buffer, isEmpty);
    bus.write32(0xa5000000, 0x00abcdef);
    bus.write32(0xa5000004, 0x00123456);
    bus.tickMasterClocks(67); // Line one is now captured.
    bus.write32(0xa5000004, 0x00fedcba);
    bus.write32(0xa5000008, 0x00224466);
    bus.tickMasterClocks(318);
    final first = bus.gpu.presentedImage;
    expect(first.buffer, [0xff332211, 0xff563412, 0xff664422]);
    bus.tickMasterClocks(400);
    expect(bus.gpu.presentedImage.buffer, [0xffefcdab, 0xffbadcfe, 0xff664422]);
    expect(first.buffer, [0xff332211, 0xff563412, 0xff664422]);
  });

  test('VO_STARTY delays source row zero until the selected display line', () {
    configure(bus, width: 1, height: 1);
    bus.write32(base + 0xf0, 1);
    bus.write32(0xa5000000, 0x00112233);
    bus.tickMasterClocks(15);
    bus.write32(0xa5000000, 0x00445566);
    bus.tickMasterClocks(67);
    bus.write32(0xa5000000, 0x00778899);
    bus.tickMasterClocks(318);
    expect(bus.gpu.presentedImage.buffer, [0xff665544]);
  });

  test(
      'VO_STARTX samples the line only after its programmed horizontal position',
      () {
    configure(bus, width: 1, height: 1);
    bus.write32(base + 0xec, 4);
    bus.write32(0xa5000000, 0x00112233);
    bus.tickMasterClocks(29); // Three video clocks, still before display start.
    bus.write32(0xa5000000, 0x00445566);
    bus.tickMasterClocks(1);
    bus.write32(0xa5000000, 0x00778899);
    bus.tickMasterClocks(370);
    expect(bus.gpu.presentedImage.buffer, [0xff665544]);
  });

  test(
      'repeated display lines can sample different values of the same source row',
      () {
    configure(bus, width: 1, height: 1, doubleLine: true);
    bus.write32(0xa5000000, 0x00112233);
    bus.tickMasterClocks(15);
    bus.write32(0xa5000000, 0x00445566);
    bus.tickMasterClocks(385);
    final image = bus.gpu.presentedImage;
    expect(image.buffer, [0xff332211, 0xff665544]);
    expect(image.height, 2);
    expect(image.displayHeight, 2);
  });

  test('horizontal clipping and pixel doubling preserve the border color', () {
    configure(bus, width: 4, height: 1);
    bus.write32(base + 0xe8, 0x100);
    bus.write32(base + 0x40, 0x00667788);
    for (var i = 0; i < 4; i++) {
      bus.write32(0xa5000000 + i * 4, 0x00112233);
    }
    bus.tickMasterClocks(400);
    expect(bus.gpu.presentedImage.buffer,
        [0xff332211, 0xff332211, 0xff332211, 0xff887766]);
    expect(bus.gpu.presentedImage.displayWidth, 8);
  });

  test(
      'blank-video changes affect upcoming lines without repainting earlier rows',
      () {
    configure(bus, width: 1);
    bus.write32(base + 0x40, 0x00445566);
    for (var i = 0; i < 3; i++) {
      bus.write32(0xa5000000 + i * 4, 0x00112233);
    }
    bus.tickMasterClocks(15);
    bus.write32(base + 0xe8, 8);
    bus.tickMasterClocks(385);
    expect(bus.gpu.presentedImage.buffer, [0xff332211, 0xff665544, 0xff665544]);
  });

  test(
      'interlaced fields use their separate vertical start positions and source pages',
      () {
    configure(bus, width: 1, height: 2, interlace: true);
    bus.write32(base + 0xf0, 1 << 16);
    bus.write32(base + 0x54, 8);
    bus.write32(0xa5000000, 0x00112233);
    bus.write32(0xa5000004, 0x00445566);
    bus.write32(0xa5000008, 0x00778899);
    bus.write32(0xa500000c, 0x00aabbcc);
    bus.tickMasterClocks(415); // Field two, line zero: before its Y start.
    bus.write32(0xa5000008, 0x00123456);
    bus.tickMasterClocks(67); // Field two, line one has now been captured.
    bus.write32(0xa5000008, 0x00fedcba);
    bus.tickMasterClocks(318);
    expect(bus.gpu.presentedImage.buffer,
        [0xff332211, 0xff563412, 0xff665544, 0xffccbbaa]);
  });

  test('a scanline samples DMA progress at display start, not at field end',
      () {
    final single = DcBus();
    for (final target in [bus, single]) {
      configure(target, width: 16, height: 1);
      target.write32(
          base + 0xd8, 0x0002001a); // 27 pixels, three lines = 600 ticks.
      target.write32(base + 0xd4, 0x0001001a);
      target.write32(base + 0xdc, 2);
      for (var i = 0; i < 120; i++) {
        target.write32(0xac020000 + i * 4, i + 1);
      }
      target.write32(0xffa00000, 0x0c020000);
      target.write32(0xffa00004, 0x05000000);
      target.write32(0xffa00008, 120);
      target.write32(0xffa0000c, 0x5431);
      target.write32(0xffa00040, 1);
    }
    bus.tickMasterClocks(600);
    for (var i = 0; i < 600; i++) {
      single.tickMasterClocks(1);
    }
    expect(bus.gpu.presentedImage.buffer, [
      for (var i = 0; i < 16; i++)
        i < 7 ? 0xff000000 | ((i + 1) << 16) : 0xff000000
    ]);
    expect(bus.gpu.presentedImage.buffer, single.gpu.presentedImage.buffer);
    expect(bus.read32(0xa500001c),
        8); // The eighth word arrived after row capture.
  });
  test(
      'changing vertical start mid-field cannot overwrite already displayed rows',
      () {
    configure(bus, width: 1);
    bus.write32(0xa5000000, 0x00112233);
    bus.write32(0xa5000004, 0x00445566);
    bus.write32(0xa5000008, 0x00778899);
    bus.tickMasterClocks(82);
    bus.write32(base + 0xf0, 1);
    bus.write32(0xa5000004, 0x00123456);
    bus.tickMasterClocks(318);
    expect(bus.gpu.presentedImage.buffer, [0xff332211, 0xff665544, 0xff563412]);
  });
  test(
      'moving the display start past upcoming rows samples their new border color',
      () {
    configure(bus, width: 1);
    bus.write32(0xa5000000, 0x00112233);
    bus.tickMasterClocks(15);
    bus.write32(base + 0xf0, 5);
    bus.write32(base + 0x40, 0x00445566);
    bus.tickMasterClocks(385);
    expect(bus.gpu.presentedImage.buffer, [0xff332211, 0xff665544, 0xff665544]);
  });
}
