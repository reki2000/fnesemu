import 'dart:typed_data';

import 'package:fnesemu_core/src/core/gb/gb.dart';
import 'package:test/test.dart';

// builds a rom image whose header has the given GBC flag (0x80: GBC-compatible, 0xc0: GBC only)
Gb _core({int gbcFlag = 0x80}) {
  final rom = Uint8List(0x8000)
    ..[0x143] = gbcFlag
    ..[0x147] = 0x00;
  return Gb()..setRom(rom);
}

void main() {
  group('mode selection', () {
    test('GBC-flagged images start with the GBC register state', () {
      final gb = _core();
      expect(gb.bus.gbc, isTrue);
      expect(gb.cpu.af, 0x1180);
      expect(gb.cpu.bc, 0x0000);
      expect(gb.cpu.de, 0xff56);
      expect(gb.cpu.hl, 0x000d);
    });

    test('GBC-only images load', () {
      expect(_core(gbcFlag: 0xc0).bus.gbc, isTrue);
    });

    test('DMG images keep the DMG register state and ignore GBC registers', () {
      final gb = _core(gbcFlag: 0x00);
      expect(gb.bus.gbc, isFalse);
      expect(gb.cpu.af, 0x01b0);
      gb.bus.write(0xff4f, 1);
      gb.bus.write(0xff70, 3);
      gb.bus.write(0xff68, 0x80);
      expect(gb.bus.read(0xff4f), 0xff);
      expect(gb.bus.read(0xff70), 0xff);
      expect(gb.bus.read(0xff68), 0xff);
      expect(gb.bus.ppu.vramBank, 0);
    });
  });

  test('WRAM bank 0 is fixed and the D000 window selects banks 1-7', () {
    final bus = _core().bus;
    bus.write(0xc000, 0x11);
    bus.write(0xd000, 0x01); // bank 1
    expect(bus.read(0xff70), 0xf9);

    bus.write(0xff70, 3);
    expect(bus.read(0xff70), 0xfb);
    expect(bus.read(0xd000), 0x00);
    bus.write(0xd000, 0x33);
    expect(bus.read(0xd000), 0x33);
    expect(bus.read(0xf000), 0x33); // echo of D000
    expect(bus.read(0xc000), 0x11);

    bus.write(0xff70, 0); // 0 selects bank 1
    expect(bus.read(0xff70), 0xf9);
    expect(bus.read(0xd000), 0x01);
  });

  test('VRAM bank 1 is selected by VBK', () {
    final gb = _core();
    final bus = gb.bus;
    bus.write(0x8000, 0x12);

    bus.write(0xff4f, 1);
    expect(bus.read(0xff4f) & 1, 1);
    expect(bus.read(0x8000), 0x00);
    bus.write(0x8000, 0x34);

    bus.write(0xff4f, 0);
    expect(bus.read(0x8000), 0x12);
    expect(gb.ppu.vram[0x2000], 0x34);
  });

  test('GBC palette writes auto-increment the index, reads do not', () {
    final bus = _core().bus;
    bus.write(0xff68, 0x80 | 6);
    bus.write(0xff69, 0x1f);
    bus.write(0xff69, 0x7c);
    expect(bus.read(0xff68), 0x80 | 8 | 0x40);

    bus.write(0xff68, 6);
    expect(bus.read(0xff69), 0x1f);
    expect(bus.read(0xff69), 0x1f);
    bus.write(0xff68, 7);
    expect(bus.read(0xff69), 0x7c);
  });

  test('general purpose VRAM DMA copies blocks into the selected bank', () {
    final gb = _core();
    final bus = gb.bus;
    for (var i = 0; i < 32; i++) {
      bus.write(0xc000 + i, i + 1);
    }

    bus.write(0xff4f, 1);
    bus.write(0xff51, 0xc0);
    bus.write(0xff52, 0x00);
    bus.write(0xff53, 0x80); // destination bits 8-12 are masked to 0x00
    bus.write(0xff54, 0x10);
    bus.write(0xff55, 0x01); // 2 blocks
    expect(bus.read(0xff55), 0xff);

    for (var i = 0; i < 32; i++) {
      expect(gb.ppu.vram[0x2000 + 0x10 + i], i + 1);
    }
    bus.write(0xff4f, 0);
    expect(bus.read(0x8010), 0x00);
  });

  test('HBlank VRAM DMA moves one block per HBlank', () {
    final gb = _core();
    final bus = gb.bus;
    for (var i = 0; i < 32; i++) {
      bus.write(0xc000 + i, 0x80 | i);
    }

    bus.write(0xff51, 0xc0);
    bus.write(0xff52, 0x00);
    bus.write(0xff53, 0x00);
    bus.write(0xff54, 0x00);
    bus.write(0xff55, 0x80 | 1); // 2 blocks, HBlank mode
    expect(bus.read(0xff55), 0x01);

    bus.hblank();
    expect(bus.read(0xff55), 0x00);
    expect(bus.read(0x8000), 0x80);
    expect(bus.read(0x800f), 0x8f);
    expect(bus.read(0x8010), 0x00);

    bus.hblank();
    expect(bus.read(0xff55), 0xff);
    expect(bus.read(0x8010), 0x90);

    bus.hblank(); // no transfer left
    expect(bus.read(0x8020), 0x00);
  });

  test('BG attributes select palette, VRAM bank and flip', () {
    final gb = _core();
    final bus = gb.bus;
    bus.write(0x8010, 0x80); // tile 1, row 0: color 1 at column 0
    bus.write(0xff68, 0x80 | 18); // BG palette 2, color 1
    bus.write(0xff69, 0x1f); // red
    bus.write(0xff69, 0x00);
    bus.write(0x9800, 1);

    bus.write(0xff4f, 1);
    bus.write(0x9800, 0x22); // palette 2, x flip
    bus.write(0xff4f, 0);

    gb.runFrame(154);
    final pixels = gb.imageBuffer().buffer;
    expect(pixels[0], 0xffffffff);
    expect(pixels[7], 0xff0000ff);
  });

  test('KEY1 armed STOP switches to double speed', () {
    final rom = Uint8List(0x8000)..[0x143] = 0x80;
    rom.setRange(
        0x100, 0x104, [0x3e, 0x01, 0xe0, 0x4d]); // LD A,1 / LDH (FF4D),A
    rom.setRange(0x104, 0x106, [0x10, 0x00]); // STOP
    final gb = Gb()..setRom(rom);
    final bus = gb.bus;

    gb.exec(false);
    gb.exec(false);
    expect(bus.read(0xff4d), 0x7f);

    gb.exec(false);
    expect(bus.doubleSpeed, isTrue);
    expect(bus.read(0xff4d), 0xfe);

    // one machine cycle is 4 CPU clocks but only 2 system clocks
    final clocks = bus.clocks, dots = bus.dotClocks;
    bus.tick();
    expect(bus.clocks - clocks, 4);
    expect(bus.dotClocks - dots, 2);
  });
}
