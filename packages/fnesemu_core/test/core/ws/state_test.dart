@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ws/ws.dart';
import 'package:fnesemu_core/src/util/state.dart';
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

// fills the tile 0 with the color 1, shows it on the screen 1 and counts
// the vblank interrupts at 0000:0100
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

// enables the sound channel 1 with its wave table over the tile data at
// 0x2000 which the program body fills afterwards
List<int> _soundSetup() => [
      0xb0, 0x80, 0xe6, 0x8f, // wave table base 0x2000
      0xb0, 0x00, 0xe6, 0x80, // channel 1 frequency low
      0xb0, 0x06, 0xe6, 0x81, // channel 1 frequency high
      0xb0, 0x99, 0xe6, 0x88, // channel 1 volume
      0xb0, 0x01, 0xe6, 0x90, // sound control: channel 1 on
    ];

void _frames(Ws ws, int frames) {
  for (var i = 0; i < frames; i++) {
    expect(ws.runFrame(ws.scanlinesInFrame).stopped, isFalse);
  }
}

void main() {
  test('WS restores into a fresh instance and continues frames and audio',
      () {
    final rom = _rom(_program(_soundSetup()));
    final original = Ws(color: false)..setRom(rom);
    _frames(original, 3);
    expect(original.bus.ram[0x100], greaterThanOrEqualTo(2));
    final state = original.saveState();

    final restored = Ws(color: false)..setRom(rom);
    final ram = restored.bus.ram, io = restored.bus.io;
    restored.loadState(state);
    expect(restored.saveState(), state);
    expect(restored.bus.ram, same(ram));
    expect(restored.bus.io, same(io));

    final pcmA = <double>[], pcmB = <double>[];
    original.onAudio((audio) => pcmA.addAll(audio.buffer));
    restored.onAudio((audio) => pcmB.addAll(audio.buffer));
    _frames(original, 3);
    _frames(restored, 3);
    expect(restored.saveState(), original.saveState());
    expect(restored.imageBuffer().buffer, original.imageBuffer().buffer);
    expect(restored.bus.ram[0x100], original.bus.ram[0x100]);
    expect(restored.cpu.cycles, original.cpu.cycles);
    expect(pcmA, isNotEmpty);
    expect(pcmA.any((sample) => sample != 0), isTrue);
    expect(pcmB, pcmA);
  });

  test('the color console restores SRAM and the EEPROM ports', () {
    final rom = _rom(_program([]), color: true, saveType: 0x01);
    final original = Ws(color: true)..setRom(rom);
    _frames(original, 2);
    final bus = original.bus;
    bus.output8(0x60, 0x80); // color mode
    bus.write8(0x10010, 0x5a); // cartridge SRAM
    bus.output8(0xc4, 0x34); // cartridge EEPROM data low byte
    bus.output8(0xc6, 0x02); // cartridge EEPROM address low byte
    bus.output8(0xba, 0x78); // internal EEPROM data low byte
    bus.output8(0xbc, 0x01); // internal EEPROM address low byte
    final state = original.saveState();

    final restored = Ws(color: true)..setRom(rom);
    restored.loadState(state);
    expect(restored.saveState(), state);
    expect(restored.bus.read8(0x10010), 0x5a);
    expect(restored.bus.input8(0xc4), 0x34);
    expect(restored.bus.input8(0xc6), 0x02);
    expect(restored.bus.input8(0xba), 0x78);
    expect(restored.bus.input8(0xbc), 0x01);
    _frames(original, 2);
    _frames(restored, 2);
    expect(restored.saveState(), original.saveState());
    expect(restored.imageBuffer().buffer, original.imageBuffer().buffer);
  });

  test('color and media mismatches fail before mutation', () {
    final rom = _rom(_program(_soundSetup()));
    final original = Ws(color: false)..setRom(rom);
    _frames(original, 1);
    final state = original.saveState();

    final salted = _rom(_program(_soundSetup()))..[0x8000] = 1;
    for (final other in [
      Ws(color: true)..setRom(_rom(_program(_soundSetup()), color: true)),
      Ws(color: false)..setRom(salted),
    ]) {
      final before = other.saveState();
      expect(() => other.loadState(state), throwsA(isA<StateMismatch>()));
      expect(other.saveState(), before);
    }

    final restored = Ws(color: false)..setRom(rom);
    final before = restored.saveState();
    expect(() => restored.loadState(state.sublist(0, state.length - 10)),
        throwsA(isA<StateMismatch>()));
    expect(restored.saveState(), before);
  });
}
