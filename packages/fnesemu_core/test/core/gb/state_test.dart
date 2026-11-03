@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:fnesemu_core/src/core/gb/gb.dart';
import 'package:fnesemu_core/src/util/state.dart';
import 'package:test/test.dart';

// builds an MBC1+RAM ROM whose program sounds channel 1, enables the
// cartridge RAM and the timer, sends a serial byte and then counts in
// WRAM while copying the count to VRAM
Uint8List _rom({int salt = 0}) {
  final rom = Uint8List(0x20000);
  rom[0x143] = 0; // DMG
  rom[0x147] = 0x03; // MBC1 + RAM + battery
  rom[0x148] = 2; // 128KB
  rom[0x149] = 2; // 8KB RAM
  rom[0x7fff] = salt;
  final prefix = <int>[
    0x3e, 0x80, 0xe0, 0x26, // NR52: power on
    0x3e, 0x80, 0xe0, 0x11, // NR11: duty 2, length 64
    0x3e, 0xf0, 0xe0, 0x12, // NR12: volume 15, no envelope period
    0x3e, 0x00, 0xe0, 0x13, // NR13: frequency low bits
    0x3e, 0x77, 0xe0, 0x24, // NR50: full volume
    0x3e, 0x11, 0xe0, 0x25, // NR51: channel 1 to both outputs
    0x3e, 0xc7, 0xe0, 0x14, // NR14: trigger, frequency 0x700
    0x3e, 0x0a, 0xea, 0x00, 0x00, // enable the cartridge RAM
    0x3e, 0x5a, 0xea, 0x00, 0xa0, // write 0x5a to the cartridge RAM
    0x3e, 0x05, 0xea, 0x00, 0x20, // MBC1: ROM bank 5
    0x3e, 0x00, 0xe0, 0x06, // TMA
    0x3e, 0xf0, 0xe0, 0x05, // TIMA
    0x3e, 0x05, 0xe0, 0x07, // TAC: enable the timer
    0x3e, 0x41, 0xe0, 0x01, // SB: 'A'
    0x3e, 0x81, 0xe0, 0x02, // SC: start the serial transfer
    0x21, 0x00, 0xc0, // LD HL, $c000
  ];
  // the program lives after the header area, reached by a jump at 0x100
  rom.setRange(0x100, 0x103, [0xc3, 0x50, 0x01]); // JP $0150
  final loop = 0x150 + prefix.length;
  rom.setRange(0x150, loop, prefix);
  rom.setRange(loop, loop + 8, [
    0x34, // INC (HL)
    0x7e, // LD A, (HL)
    0xea, 0x00, 0x80, // LD ($8000), A
    0xc3, loop & 0xff, loop >> 8, // JP loop
  ]);
  return rom;
}

Gb _system({int salt = 0}) => Gb()..setRom(_rom(salt: salt));

void _frames(Gb gb, int frames) {
  for (var i = 0; i < frames; i++) {
    expect(gb.runFrame(gb.scanlinesInFrame).stopped, isFalse);
  }
}

void main() {
  test('GB restores into a fresh instance and continues frames and audio',
      () {
    final original = _system();
    _frames(original, 2);
    expect(original.bus.serialOutput.toString(), 'A');
    final state = original.saveState();

    final restored = _system();
    final wram = restored.bus.wram, vram = restored.ppu.vram;
    restored.loadState(state);
    expect(restored.saveState(), state);
    expect(restored.bus.wram, same(wram));
    expect(restored.ppu.vram, same(vram));
    expect(restored.read(0, 0xa000), 0x5a);
    expect(restored.bus.serialOutput.toString(), 'A');

    final pcmA = <double>[], pcmB = <double>[];
    original.onAudio((audio) => pcmA.addAll(audio.buffer));
    restored.onAudio((audio) => pcmB.addAll(audio.buffer));
    _frames(original, 3);
    _frames(restored, 3);
    expect(restored.saveState(), original.saveState());
    expect(restored.imageBuffer().buffer, original.imageBuffer().buffer);
    expect(restored.cpu.pc, original.cpu.pc);
    expect(restored.bus.wram[0], original.bus.wram[0]);
    expect(pcmA, isNotEmpty);
    expect(pcmA.any((sample) => sample != 0), isTrue);
    expect(pcmB, pcmA);
  });

  test('GBC banks, palettes and HDMA registers survive a round trip', () {
    Uint8List rom() {
      final bytes = Uint8List(0x8000);
      bytes[0x143] = 0x80; // GBC compatible
      bytes[0x147] = 0x00;
      bytes.setRange(0x100, 0x103, [0xc3, 0x00, 0x01]); // JP $0100
      return bytes;
    }

    final original = Gb()..setRom(rom());
    _frames(original, 1);
    final bus = original.bus;
    bus.write(0xff70, 3); // WRAM bank 3
    bus.write(0xd000, 0x33);
    bus.write(0xff4f, 1); // VRAM bank 1
    bus.write(0x8000, 0x99);
    bus.write(0xff68, 0x80); // BCPS with auto increment
    bus.write(0xff69, 0xff);
    bus.write(0xff69, 0x7f);
    bus.write(0xff51, 0xc0); // HDMA source
    bus.write(0xff52, 0x00);
    bus.write(0xff53, 0x10); // HDMA destination
    bus.write(0xff54, 0x00);
    final state = original.saveState();

    final restored = Gb()..setRom(rom());
    restored.loadState(state);
    expect(restored.saveState(), state);
    expect(restored.bus.read(0xd000), 0x33);
    expect(restored.bus.read(0x8000), 0x99);
    expect(restored.bus.read(0xff69), 0xff);
    _frames(original, 2);
    _frames(restored, 2);
    expect(restored.saveState(), original.saveState());
    expect(restored.imageBuffer().buffer, original.imageBuffer().buffer);
  });

  test('media mismatches and truncated states fail before mutation', () {
    final original = _system();
    _frames(original, 1);
    final state = original.saveState();
    for (final other in [_system(salt: 1)]) {
      final before = other.saveState();
      expect(() => other.loadState(state), throwsA(isA<StateMismatch>()));
      expect(other.saveState(), before);
    }
    final restored = _system();
    final before = restored.saveState();
    expect(() => restored.loadState(state.sublist(0, state.length - 10)),
        throwsA(isA<StateMismatch>()));
    expect(() => restored.loadState(Uint8List(3)),
        throwsA(isA<StateMismatch>()));
    expect(restored.saveState(), before);
  });
}
