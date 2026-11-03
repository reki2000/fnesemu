import 'dart:typed_data';

import 'package:fnesemu_core/src/core/nes/nes.dart';
import 'package:fnesemu_core/src/util/state.dart';
import 'package:test/test.dart';

/// An iNES image whose program counts in zero page and in RAM page 2, with the APU pulse channel and the PPU control register set.
Uint8List _nrom() {
  final bytes = Uint8List(16 + 0x8000 + 0x2000);
  bytes.setAll(0, [0x4e, 0x45, 0x53, 0x1a, 2, 1, 0, 0]);
  final program = [
    0x78, // SEI
    0xa9, 0x0f, 0x8d, 0x15, 0x40, // LDA #$0f; STA $4015
    0xa9, 0x80, 0x8d, 0x00, 0x20, // LDA #$80; STA $2000
    0xa9, 0x10, 0x8d, 0x00, 0x40, // LDA #$10; STA $4000
    0xe6, 0x00, // loop: INC $00
    0xee, 0x00, 0x02, // INC $0200
    0x4c, 0x10, 0x80, // JMP loop
  ];
  bytes.setAll(16, program);
  // The reset vector lives in the last PRG bank, mirrored at $fffc.
  bytes.setAll(16 + 0x7ffc, [0x00, 0x80]);
  return bytes;
}

/// An MMC3 image whose program selects CHR and PRG banks, arms the scanline IRQ and writes cartridge RAM before counting in zero page.
Uint8List _mmc3() {
  final bytes = Uint8List(16 + 0x10000 + 0x4000);
  bytes.setAll(0, [0x4e, 0x45, 0x53, 0x1a, 4, 2, 0x40, 0]);
  final program = [
    0x78, // SEI
    0xa9, 0x00, 0x8d, 0x00, 0x80, // LDA #$00; STA $8000 (select R0)
    0xa9, 0x04, 0x8d, 0x01, 0x80, // LDA #$04; STA $8001 (R0 = 4)
    0xa9, 0x06, 0x8d, 0x00, 0x80, // LDA #$06; STA $8000 (select R6)
    0xa9, 0x02, 0x8d, 0x01, 0x80, // LDA #$02; STA $8001 (R6 = 2)
    0xa9, 0x03, 0x8d, 0x00, 0xc0, // LDA #$03; STA $c000 (IRQ latch)
    0x8d, 0x01, 0xc0, // STA $c001 (IRQ reload)
    0x8d, 0x01, 0xe0, // STA $e001 (IRQ enable)
    0xa9, 0x5a, 0x8d, 0x00, 0x60, // LDA #$5a; STA $6000 (cartridge RAM)
    0xe6, 0x00, // loop: INC $00
    0x4c, 0x25, 0xe0, // JMP loop
  ];
  // The fixed last 8 KiB bank is mapped at $e000.
  bytes.setAll(16 + 0xe000, program);
  bytes[16 + 0xe100] = 0x40; // RTI for the interrupt vectors
  bytes.setAll(16 + 0xfffa, [0x00, 0xe1, 0x00, 0xe0, 0x00, 0xe1]);
  return bytes;
}

Nes _system(Uint8List rom) => Nes()..setRom(rom);

void _frames(Nes nes, int count) {
  for (var i = 0; i < count; i++) {
    expect(nes.runFrame(nes.scanlinesInFrame).stopped, isFalse);
  }
}

void main() {
  for (final (name, rom) in [('NROM', _nrom()), ('MMC3', _mmc3())]) {
    test('$name restores into a fresh instance and continues identically', () {
      final original = _system(rom);
      _frames(original, 2);
      expect(original.bus.ram[0], isNonZero);
      final state = original.saveState();

      final restored = _system(rom);
      final ram = restored.bus.ram, vram = restored.bus.vram;
      restored.loadState(state);
      expect(restored.saveState(), state);
      expect(restored.bus.ram, same(ram));
      expect(restored.bus.vram, same(vram));
      expect(restored.cpu.bus, same(restored.bus));

      final pcmA = <double>[], pcmB = <double>[];
      original.onAudio((audio) => pcmA.addAll(audio.buffer));
      restored.onAudio((audio) => pcmB.addAll(audio.buffer));
      for (var i = 0; i < 3; i++) {
        _frames(original, 1);
        _frames(restored, 1);
        expect(restored.saveState(), original.saveState());
        expect(restored.imageBuffer().buffer, original.imageBuffer().buffer);
      }
      expect(pcmA, isNotEmpty);
      expect(pcmB, pcmA);
    });
  }

  test('MMC3 cartridge RAM and bank registers survive a restore', () {
    final original = _system(_mmc3());
    _frames(original, 1);
    expect(original.bus.mapper.read(0x6000), 0x5a);
    final restored = _system(_mmc3());
    restored.loadState(original.saveState());
    expect(restored.bus.mapper.read(0x6000), 0x5a);
    expect(restored.bus.mapper.read(0x8000), original.bus.mapper.read(0x8000));
    expect(restored.bus.mapper.readVram(0x0000),
        original.bus.mapper.readVram(0x0000));
  });

  test('a state of different media fails before mutation', () {
    final original = _system(_nrom());
    _frames(original, 1);
    final state = original.saveState();
    final otherRom = _nrom();
    otherRom[16 + 0x100] ^= 0xff;
    final other = _system(otherRom);
    _frames(other, 1);
    final before = other.saveState();
    expect(() => other.loadState(state), throwsA(isA<StateMismatch>()));
    expect(other.saveState(), before);
  });

  test('FDS restores the adapter RAM, timer and drive state', () {
    Uint8List bios() {
      final result = Uint8List(8192);
      result.setAll(0, [
        0x78, // SEI
        0xa9, 0x03, 0x8d, 0x23, 0x40, // LDA #$03; STA $4023 (I/O enable)
        0xa9, 0xff, 0x8d, 0x20, 0x40, // LDA #$ff; STA $4020 (timer low)
        0xa9, 0x00, 0x8d, 0x21, 0x40, // LDA #$00; STA $4021 (timer high)
        0xa9, 0x02, 0x8d, 0x22, 0x40, // LDA #$02; STA $4022 (timer on)
        0xa9, 0x42, 0x8d, 0x00, 0x60, // LDA #$42; STA $6000 (adapter RAM)
        0xe6, 0x00, // loop: INC $00
        0x4c, 0x1a, 0xe0, // JMP loop
      ]);
      result.setAll(0x1ffa, [0x1a, 0xe0, 0x00, 0xe0, 0x1a, 0xe0]);
      return result;
    }

    Uint8List disk() {
      final result = Uint8List(16 + 65500);
      result.setAll(0, [0x46, 0x44, 0x53, 0x1a, 1]);
      result[16] = 1;
      result.setAll(17, List.filled(14, 0x2a));
      result.setAll(16 + 56, [2, 1, 3]);
      return result;
    }

    Nes fds() => Nes(diskSystem: true)
      ..setBiosFiles([bios()])
      ..setRom(disk());

    final original = fds();
    _frames(original, 2);
    expect(original.bus.read(0x6000), 0x42);
    final state = original.saveState();
    final restored = fds();
    restored.loadState(state);
    expect(restored.saveState(), state);
    for (var i = 0; i < 2; i++) {
      _frames(original, 1);
      _frames(restored, 1);
      expect(restored.saveState(), original.saveState());
    }
  });
}
