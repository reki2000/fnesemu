import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ws/bus.dart';
import 'package:fnesemu_core/src/core/ws/v30mz/disasm.dart';
import 'package:fnesemu_core/src/core/ws/ws.dart';
import 'package:fnesemu_core/src/pad_button.dart';
import 'package:fnesemu_core/src/types.dart';
import 'package:test/test.dart';

// builds a 64KB rom with [code] at F000:0000, entered from FFFF:0000
Uint8List _rom(List<int> code, {bool color = false, int saveType = 0}) {
  final rom = Uint8List(0x10000);
  rom.setRange(0, code.length, code);
  rom.setAll(0xfff0, [0xea, 0x00, 0x00, 0x00, 0xf0]); // jmp f000:0000
  rom[0xfff7] = color ? 1 : 0;
  rom[0xfffb] = saveType;
  return rom;
}

// fills the tile 0 with the color 1, shows it on the screen 1 and counts the
// vblank interrupts at 0000:0100
List<int> _program(List<int> setup) {
  final code = [
    0xb8, 0x00, 0x00, // mov ax, 0
    0x8e, 0xc0, // mov es, ax
    0x8e, 0xd8, // mov ds, ax
    ...setup,
    0xbf, 0x00, 0x20, // mov di, 0x2000
    0xb9, 0x08, 0x00, // mov cx, 8
    0xb8, 0xff, 0x00, // mov ax, 0x00ff
    0xf3, 0xab, // rep stosw
    0xb0, 0x01, // mov al, 1
    0xe6, 0x07, // out 0x07, al: screen 1 map at 0x0800
    0xe6, 0x00, // out 0x00, al: screen 1 on
    0xb0, 0x08, // mov al, 8
    0xe6, 0xb0, // out 0xb0, al: interrupt base 8
    0xb0, 0x40, // mov al, 0x40
    0xe6, 0xb2, // out 0xb2, al: vblank interrupt
    0xc7, 0x06, 0x38, 0x00, 0x00, 0x00, // mov word [0x38], handler
    0xc7, 0x06, 0x3a, 0x00, 0x00, 0xf0, // mov word [0x3a], 0xf000
    0xfb, // sti
    0xf4, // hlt
    0xeb, 0xfd, // jmp -3
  ];
  final handler = code.length;
  code[code.length - 12] = handler & 0xff;
  code[code.length - 11] = handler >> 8;
  return [
    ...code,
    0xff, 0x06, 0x00, 0x01, // inc word [0x0100]
    0xb0, 0x40, // mov al, 0x40
    0xe6, 0xb6, // out 0xb6, al
    0xcf, // iret
  ];
}

Ws _run(Uint8List rom, {required bool color, int frames = 3}) {
  final ws = Ws(color: color)..setRom(rom);
  ws.runFrame(159 * frames);
  return ws;
}

int _pixel(ImageBuffer image, int x, int y) =>
    image.buffer[y * image.width + x];

void main() {
  test('mono tiles use the shade pool and vblank interrupts are counted', () {
    final ws = _run(
        _rom(_program([
          0xb0, 0x70, // mov al, 0x70: palette 0 color 1 = shade 7
          0xe6, 0x20, // out 0x20, al
        ])),
        color: false);
    expect(ws.bus.ram[0x100], greaterThanOrEqualTo(2));
    final image = ws.imageBuffer();
    expect(image.width, 224);
    expect(image.height, 144);
    expect(_pixel(image, 100, 100), 0xff000000);
  });

  test('color mode uses the palette RAM', () {
    final ws = _run(
        _rom(
            _program([
              0xb0, 0x80, // mov al, 0x80
              0xe6, 0x60, // out 0x60, al: color mode
              0xc7, 0x06, 0x02, 0xfe, 0x00, 0x0f, // mov [0xfe02], 0x0f00
            ]),
            color: true),
        color: true);
    expect(ws.bus.ram[0x100], greaterThanOrEqualTo(2));
    expect(_pixel(ws.imageBuffer(), 10, 10), 0xff0000ff);
  });

  test('the upper RAM is not accessible in the mono mode', () {
    final bus = (Ws(color: true)..setRom(_rom([]))).bus;
    bus.write8(0x8000, 0x12);
    expect(bus.read8(0x8000), 0x90);
    bus.output8(0x60, 0x80);
    bus.write8(0x8000, 0x12);
    expect(bus.read8(0x8000), 0x12);
  });

  test('ROM banks are aligned to the end of the address space', () {
    final rom = Uint8List(0x40000);
    for (var bank = 0; bank < 4; bank++) {
      rom[bank * 0x10000] = bank;
    }
    rom.setAll(0x3fff0, [0xea, 0, 0, 0, 0xf0]);
    final bus = (Ws(color: false)..setRom(rom)).bus;
    expect(bus.read8(0xf0000), 3);
    bus.output8(0xc2, 1);
    expect(bus.read8(0x20000), 1);
    bus.output8(0xc0, 0);
    expect(bus.read8(0x40000), 0);
  });

  test('SRAM is mapped by the save type', () {
    final bus = (Ws(color: false)..setRom(_rom([], saveType: 1))).bus;
    bus.write8(0x10010, 0x5a);
    expect(bus.read8(0x10010), 0x5a);
    expect(bus.read8(0x12010), 0x5a); // 8KB mirror
  });

  test('keys are read by groups and raise the key interrupt', () {
    final ws = Ws(color: false)..setRom(_rom([]));
    ws.bus.output8(0xb2, 0x02);
    ws.padDown(0, PadButton.up);
    ws.padDown(0, Pad.a);
    ws.bus.output8(0xb5, 0x20);
    expect(ws.bus.input8(0xb5), 0x21);
    ws.bus.output8(0xb5, 0x40);
    expect(ws.bus.input8(0xb5), 0x44);
    expect(ws.bus.input8(0xb4) & 0x02, 0x02);
  });

  test('keyboard slots match the horizontal WS layout', () {
    final buttons = Ws(color: false).buttons;
    expect(buttons, [
      PadButton.up, PadButton.down, PadButton.left, PadButton.right,
      Pad.y4, Pad.y3, Pad.b, Pad.a, PadButton.none, Pad.sound,
      Pad.y1, Pad.start, Ws.rotate, Pad.y2,
    ]);
  });

  test('Sound cycles speaker output level without modifying keypad scan', () {
    final ws = Ws(color: false)..setRom(_rom([0xeb, 0xfe]));
    ws.bus.output8(0xb5, 0x70);
    expect(ws.speakerVolume, 3);
    for (final level in [2, 1, 0, 3]) {
      ws.padDown(0, Pad.sound);
      expect(ws.speakerVolume, level);
      expect(ws.bus.input8(0xb5), 0x70);
    }
  });

  test('horizontal directions and Y keys use independent groups', () {
    final ws = Ws(color: false)..setRom(_rom([]));
    final cases = [
      (PadButton.up, 0x20, 1),
      (PadButton.right, 0x20, 2),
      (PadButton.down, 0x20, 4),
      (PadButton.left, 0x20, 8),
      (Pad.y1, 0x10, 1),
      (Pad.y2, 0x10, 2),
      (Pad.y3, 0x10, 4),
      (Pad.y4, 0x10, 8),
    ];
    for (final (button, select, bit) in cases) {
      ws.padDown(0, button);
      ws.bus.output8(0xb5, select);
      expect(ws.bus.input8(0xb5), select | bit,
          reason: 'horizontal input ${button.name}');
      ws.padUp(0, button);
      expect(ws.bus.input8(0xb5), select);
    }
  });

  test('vertical arrows use Y and WASD uses the rotated X group', () {
    final ws = Ws(color: false)..setRom(_rom([]));
    ws.padDown(0, Ws.rotate);
    ws.padUp(0, Ws.rotate);

    final cases = [
      (PadButton.up, 0x10, 2),
      (PadButton.right, 0x10, 4),
      (PadButton.down, 0x10, 8),
      (PadButton.left, 0x10, 1),
      (Pad.y1, 0x20, 2),
      (Pad.y2, 0x20, 4),
      (Pad.y3, 0x20, 8),
      (Pad.y4, 0x20, 1),
    ];
    for (final (button, select, bit) in cases) {
      ws.padDown(0, button);
      ws.bus.output8(0xb5, select);
      expect(ws.bus.input8(0xb5), select | bit,
          reason: 'vertical input ${button.name}');
      ws.padUp(0, button);
      expect(ws.bus.input8(0xb5), select);
    }
  });

  test('held arrow and WASD keys rebind when rotating', () {
    final ws = Ws(color: false)..setRom(_rom([]));
    ws.padDown(0, PadButton.up);
    ws.padDown(0, Pad.y1);
    ws.bus.output8(0xb5, 0x30);
    expect(ws.bus.input8(0xb5), 0x31);

    ws.padDown(0, Ws.rotate);
    ws.padUp(0, Ws.rotate);
    // Arrow Up now uses Y2 and W now uses X2.
    expect(ws.bus.input8(0xb5), 0x32);

    ws.padUp(0, PadButton.up);
    ws.bus.output8(0xb5, 0x10);
    expect(ws.bus.input8(0xb5), 0x10);
    ws.bus.output8(0xb5, 0x20);
    expect(ws.bus.input8(0xb5), 0x22);
    ws.padUp(0, Pad.y1);
    expect(ws.bus.input8(0xb5), 0x20);

    ws.padDown(0, PadButton.left);
    ws.padDown(0, Pad.y4);
    ws.bus.output8(0xb5, 0x30);
    expect(ws.bus.input8(0xb5), 0x31);
    ws.padDown(0, Ws.rotate);
    ws.padUp(0, Ws.rotate);
    expect(ws.bus.input8(0xb5), 0x38);
    ws.padUp(0, PadButton.left);
    ws.padUp(0, Pad.y4);
    expect(ws.bus.input8(0xb5), 0x30);
  });

  test('a wave channel produces audio', () {
    final ws = Ws(color: false)..setRom(_rom([0xeb, 0xfe]));
    final buffers = <AudioBuffer>[];
    ws.onAudio(buffers.add);
    final bus = ws.bus;
    for (var i = 0; i < 16; i++) {
      bus.ram[i] = i < 8 ? 0xff : 0x00; // square wave at 0x0000
    }
    bus.output8(0x80, 0x00);
    bus.output8(0x81, 0x07);
    bus.output8(0x88, 0xff);
    bus.output8(0x90, 0x01);
    ws.runFrame(159 * 2);
    final samples = buffers.expand((b) => b.buffer);
    expect(samples.any((v) => v > 0), isTrue);
    expect(samples.any((v) => v == 0), isTrue);

    // The console SOUND key mutes the emulated speaker output.
    for (var i = 0; i < 3; i++) {
      ws.padDown(0, Pad.sound);
    }
    buffers.clear();
    ws.runFrame(159);
    expect(buffers, isNotEmpty);
    expect(buffers.expand((b) => b.buffer).every((v) => v == 0), isTrue);
  });

  test('the vertical console turns the frame and the directions', () {
    final ws = Ws(color: false)..setRom(_rom([0xeb, 0xfe]));
    ws.runFrame(159);
    final flat = ws.imageBuffer();
    // mark the top-left pixel to follow it through the turn
    flat.buffer[0] = 0x12345678;
    expect(ws.buttons[12], Ws.rotate);

    ws.padDown(0, Ws.rotate);
    ws.padUp(0, Ws.rotate);
    final turned = ws.imageBuffer();
    expect((turned.width, turned.height), (flat.height, flat.width));
    // turned to the left: the top-left corner goes to the bottom-left
    expect(turned.buffer[(flat.width - 1) * turned.width], 0x12345678);

    // Arrows now activate the Y group in vertical mode.
    ws.padDown(0, PadButton.up);
    expect(ws.bus.pad.read(0x10) & 0x0f, 2);
    ws.padUp(0, PadButton.up);
    ws.padDown(0, PadButton.left);
    expect(ws.bus.pad.read(0x10) & 0x0f, 1);

    // Turning back moves a held direction into the horizontal X group.
    ws.padDown(0, Ws.rotate);
    expect(ws.bus.pad.read(0x10) & 0x0f, 0);
    expect(ws.bus.pad.read(0x20) & 0x0f, 8);
    ws.padUp(0, PadButton.left);
    expect(ws.bus.pad.read(0x20) & 0x0f, 0);
    expect(ws.imageBuffer().width, flat.width);
  });

  test('the disassembler decodes modrm operands', () {
    final code = [0x26, 0x8b, 0x47, 0xfe, 0xc3];
    expect(disasmV30((i) => code[i], 0), ('mov ax, word es:[bx-02]', 4));
    expect(disasmV30((i) => code[4 + i], 0), ('ret', 1));
  });
}
