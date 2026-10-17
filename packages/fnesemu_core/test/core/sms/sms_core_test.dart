import 'dart:typed_data';

import 'package:fnesemu_core/src/core/sms/bus.dart';
import 'package:fnesemu_core/src/core/sms/pad.dart';
import 'package:fnesemu_core/src/core/sms/sms.dart';
import 'package:fnesemu_core/src/pad_button.dart';
import 'package:fnesemu_core/src/types.dart';
import 'package:test/test.dart';

// builds a rom image from the code blocks placed at their addresses
Uint8List _rom(Map<int, List<int>> blocks, {int size = 0x8000}) {
  final rom = Uint8List(size);
  for (final MapEntry(key: addr, value: code) in blocks.entries) {
    rom.setRange(addr, addr + code.length, code);
  }
  return rom;
}

// sets the VDP registers from the table at 0x0050, then runs [body] and
// waits for interrupts. the interrupt handler counts frames at 0xc000
Uint8List _program(List<int> registers, List<int> body) => _rom({
      0x0000: [
        0xf3, // di
        0x31, 0xf0, 0xdf, // ld sp, $dff0
        0xed, 0x56, // im 1
        0x21, 0x50, 0x00, // ld hl, $0050
        0x06, registers.length, // ld b, n
        0x0e, 0xbf, // ld c, $bf
        0xed, 0xb3, // otir
        0xc3, 0x00, 0x01, // jp $0100
      ],
      0x0038: [
        0xf5, // push af
        0xdb, 0xbf, // in a, ($bf)
        0x3a, 0x00, 0xc0, // ld a, ($c000)
        0x3c, // inc a
        0x32, 0x00, 0xc0, // ld ($c000), a
        0xf1, // pop af
        0xfb, // ei
        0xc9, // ret
      ],
      0x0050: registers,
      0x0100: [
        ...body,
        0xfb, // ei
        0x76, // halt
        0x18, 0xfd, // jr -3
      ],
    });

// out ($bf) with the two bytes of a VDP command
List<int> _command(int low, int high) =>
    [0x3e, low, 0xd3, 0xbf, 0x3e, high, 0xd3, 0xbf];

List<int> _data(int value) => [0x3e, value, 0xd3, 0xbe];

Sms _run(SmsModel model, Uint8List rom, int frames) {
  final sms = Sms(model)..setRom(rom);
  sms.runFrame(262 * frames);
  return sms;
}

int _pixel(ImageBuffer image, int x, int y) =>
    image.buffer[y * image.width + x];

void main() {
  test('mode 4 renders tiles with the palette and counts frame interrupts', () {
    final rom = _program([
      0x04, 0x80, 0x60, 0x81, 0xff, 0x82, 0xff, 0x83, 0xff, 0x84, //
      0xff, 0x85, 0xfb, 0x86, 0x00, 0x87, 0x00, 0x88, 0x00, 0x89, 0xff, 0x8a,
    ], [
      ..._command(0x00, 0x40), // vram 0x0000
      0x06, 0x08, // ld b, 8
      ..._data(0xff), 0xaf, 0xd3, 0xbe, 0xd3, 0xbe, 0xd3, 0xbe, // color 1
      0x10, 0xf3, // djnz
      ..._command(0x01, 0xc0), // cram 1
      ..._data(0x03), // red
    ]);
    final sms = _run(SmsModel.sms, rom, 4);
    expect(sms.bus.ram[0], greaterThanOrEqualTo(3));
    final image = sms.imageBuffer();
    expect(image.width, 256);
    expect(image.height, 192);
    expect(_pixel(image, 100, 100), 0xff0000ff);
  });

  test('graphics I mode of the SG-1000 uses the fixed palette', () {
    final rom = _program([
      0x00, 0x80, 0x60, 0x81, 0x0e, 0x82, 0x80, 0x83, 0x00, 0x84, //
      0x76, 0x85, 0x00, 0x86, 0x01, 0x87,
    ], [
      ..._command(0x00, 0x40), // patterns
      0x06, 0x08, ..._data(0xf0), 0x10, 0xfa, // left half: foreground
      ..._command(0x00, 0x60), // color table 0x2000
      ..._data(0xf4), // white on dark blue
    ]);
    final sms = _run(SmsModel.sg1000, rom, 3);
    expect(sms.bus.ram[0], greaterThanOrEqualTo(2));
    final image = sms.imageBuffer();
    expect(_pixel(image, 0, 0), 0xffffffff);
    expect(_pixel(image, 4, 0), 0xffed5554);
  });

  test('the Game Gear shows a 160x144 window with 12-bit colors', () {
    final rom = _program([
      0x04, 0x80, 0x60, 0x81, 0xff, 0x82, 0xff, 0x83, 0xff, 0x84, //
      0xff, 0x85, 0xfb, 0x86, 0x00, 0x87,
    ], [
      ..._command(0x00, 0xc0), // cram 0: background color 0
      ..._data(0x0f), ..._data(0x08), // r=15 g=0 b=8
    ]);
    final sms = _run(SmsModel.gg, rom, 3);
    final image = sms.imageBuffer();
    expect(image.width, 160);
    expect(image.height, 144);
    expect(_pixel(image, 10, 10), 0xff8800ff);
  });

  test('the Sega mapper switches banks and the cartridge RAM', () {
    final rom = Uint8List(0x20000);
    for (var bank = 0; bank < 8; bank++) {
      rom[bank * 0x4000 + 0x10] = bank;
    }
    final bus = (Sms(SmsModel.sms)..setRom(rom)).bus;
    expect(bus.mapper, Mapper.sega);
    expect(bus.read(0x8010), 2);
    bus.write(0xffff, 5);
    expect(bus.read(0x8010), 5);
    bus.write(0xfffe, 7);
    expect(bus.read(0x4010), 7);
    bus.write(0xfffc, 0x08);
    bus.write(0x8010, 0x42);
    expect(bus.read(0x8010), 0x42);
    bus.write(0xfffc, 0x00);
    expect(bus.read(0x8010), 5);
  });

  test('the pause button raises an NMI', () {
    final rom = _rom({
      0x0000: [0x31, 0xf0, 0xdf, 0x18, 0xfe], // ld sp; jr $
      0x0066: [0x3e, 0x99, 0x32, 0x00, 0xc0, 0xed, 0x45], // ld ($c000), a
    });
    final sms = Sms(SmsModel.sms)..setRom(rom);
    sms.runFrame(10);
    sms.padDown(0, Pad.pause);
    sms.runFrame(10);
    expect(sms.bus.ram[0], 0x99);
  });

  test('pads are read active low on the port 0xdc', () {
    final sms = Sms(SmsModel.sms)..setRom(Uint8List(0x8000));
    expect(sms.bus.input(0xdc), 0xff);
    sms.padDown(0, PadButton.up);
    sms.padDown(0, Pad.button2);
    expect(sms.bus.input(0xdc), 0xde);
    sms.padUp(0, PadButton.up);
    expect(sms.bus.input(0xdc), 0xdf);
  });

  test('audio is produced every frame', () {
    final sms = Sms(SmsModel.sms)..setRom(Uint8List(0x8000));
    final buffers = <AudioBuffer>[];
    sms.onAudio(buffers.add);
    sms.runFrame(262 * 3);
    expect(buffers, isNotEmpty);
    expect(buffers.first.sampleRate, Sms.sampleRate);
    expect(buffers.last.buffer.length, closeTo(Sms.sampleRate / 60 * 2, 8));
  });
}
