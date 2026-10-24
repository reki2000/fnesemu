import 'dart:typed_data';

import 'package:fnesemu_core/src/core/n64/bus.dart';
import 'package:fnesemu_core/src/core/n64/graphics.dart';
import 'package:fnesemu_core/src/core/n64/n64.dart';
import 'package:fnesemu_core/src/sram.dart';
import 'package:test/test.dart';

void _dma(N64Bus bus, int cart, int dram, int length, {bool read = true}) {
  bus.write(0xa4600000, dram, 4);
  bus.write(0xa4600004, cart, 4);
  bus.write(read ? 0xa460000c : 0xa4600008, length - 1, 4);
}

void main() {
  test('the startup task stores cold vector data and completes through SP', () {
    final core = N64(jit: false);
    addTearDown(core.dispose);
    final task = ByteData.sublistView(core.bus.sp, 0xfc0);
    task.setUint32(0, 4);
    task.setUint32(16, 0x1000);
    task.setUint32(20, 0x20);
    task.setUint32(24, 0x2000);
    task.setUint32(28, 8);
    const code = [0xe80c2001, 0x34014000, 0x40812000, 0x0000000d];
    for (var i = 0; i < code.length; i++) {
      core.bus.ramWrite(0x1000 + i * 4, code[i], 4);
    }
    core.bus.ram.fillRange(0x2000, 0x2008, 0x55);
    core.bus.sp.fillRange(8, 16, 0xff);
    core.bus.write(0xa4040010, 0x101, 4); // Clear HALT, enable break IRQ.
    expect(core.bus.sp.sublist(0, 8), List.filled(8, 0x55));
    expect(core.bus.sp.sublist(8, 16), List.filled(8, 0));
    expect(core.bus.spRegs[4] & 0x203, 0x203);
    expect(core.bus.mi[2] & 1, 1);
    task.setUint32(20, 0x1000); // A JPEG task must not be swallowed.
    expect(() => core.bus.onTask!(), throwsUnsupportedError);
  });

  test('FlashRAM ID, buffered program, old-chip read addressing and erase', () {
    final bus = N64Bus()..reset();
    void command(int value) => bus.write(0xa8010000, value, 4);
    command(0xe1000000);
    _dma(bus, 0x08000000, 0x1000, 8);
    expect(bus.ramRead(0x1000, 4), 0x11118001);
    expect(bus.ramRead(0x1004, 4), 0x00c2001e);
    bus.ram.fillRange(0x2000, 0x2080, 0x5a);
    command(0xb4000000);
    _dma(bus, 0x08000000, 0x2000, 128, read: false);
    command(0xa5000101);
    expect(bus.flash.sublist(0x8080, 0x8100), List.filled(128, 0x5a));
    expect(bus.read(0xa8000000, 4) & 255, 4); // Program complete, no busy bits.
    command(0xd2000000);
    bus.write(0xa8000000, 0, 4); // Clear status, preserving programmed data.
    expect(bus.read(0xa8000000, 4), 0);
    command(0xf0000000);
    _dma(bus, 0x08004040, 0x3000, 128);
    expect(bus.ram.sublist(0x3000, 0x3080), List.filled(128, 0x5a));
    bus.flash[0x8000] = 0;
    bus.flash[0x7fff] = 0;
    command(0x4b000101);
    command(0x78000000);
    expect(bus.flash.sublist(0x8000, 0xc000), List.filled(0x4000, 255));
    expect(bus.flash[0x7fff], 0);
    command(0x3c000000);
    command(0x78000000);
    expect(bus.flash, everyElement(255));
  });

  test('FlashRAM writes persist through the core backup and reset', () {
    final bus = N64Bus()..sram = Sram();
    bus.sram!.init(
        'test',
        Uint8List(N64Bus.flashOffset + 0x20000)
          ..fillRange(N64Bus.flashOffset, N64Bus.flashOffset + 0x20000, 255));
    bus.write(0xa8010000, 0xb4000000, 4);
    bus.ram.fillRange(0x1000, 0x1080, 0x3c);
    _dma(bus, 0x08000000, 0x1000, 128, read: false);
    bus.write(0xa8010000, 0xa50003ff, 4);
    bus.write(0xa8010000, 0xd2000000, 4);
    bus.reset();
    bus.write(0xa8010000, 0xf0000000, 4);
    _dma(bus, 0x0800ffc0, 0x2000, 128);
    expect(bus.ram.sublist(0x2000, 0x2080), List.filled(128, 0x3c));
    expect(bus.sram!.read8(N64Bus.flashOffset + 0x1ffff), 0x3c);
  });

  test('LOAD_UCODE switches to a scaled S2DEX background and back', () {
    final bus = N64Bus();
    final gfx = N64Graphics(bus);
    const f3d = 'RSP Gfx ucode F3DZEX.NoN fifo 2.08';
    const s2d = 'RSP Gfx ucode S2DEX fifo 2.08';
    bus.ram.setAll(0x1000, f3d.codeUnits);
    bus.ram.setAll(0x1800, s2d.codeUnits);
    void word(int a, int v) => bus.ramWrite(a, v, 4);
    // A two-pixel source scaled to four pixels, cropped to the last three.
    bus.ramWrite(0x3002, 8, 2);
    bus.ramWrite(0x3006, 16, 2);
    bus.ramWrite(0x300a, 4, 2);
    bus.ramWrite(0x300e, 4, 2);
    word(0x3010, 0x4000);
    bus.ram[0x3017] = 2;
    bus.ramWrite(0x301c, 512, 2);
    bus.ramWrite(0x301e, 1024, 2);
    word(0x4000, 0xf80107c1); // Red, green RGBA16.
    const commands = [
      0xff100003,
      0x5000,
      0xe1000000,
      0x1800,
      0xdd0007ff,
      0,
      0x0b000000,
      0x0c,
      0x09000000,
      0x3000,
      0xe1000000,
      0x1000,
      0xdd0007ff,
      0,
      0xdf000000,
      0,
    ];
    for (var i = 0; i < commands.length; i++) {
      word(0x2000 + i * 4, commands[i]);
    }
    gfx.scLeft = 1;
    gfx.combine1 = (1 << 15) | (1 << 9); // TEXEL0 color and alpha.
    gfx.task(0x2000, commands.length * 4, 0x1000, 0x800);
    expect(bus.ramRead(0x5000, 2), 0);
    expect(bus.ramRead(0x5002, 2), 0xf801);
    expect(bus.ramRead(0x5004, 2), 0x07c1);
    expect(bus.ramRead(0x5006, 2), 0x07c1);
    expect(gfx.f3dex2, isTrue);
  });
}
