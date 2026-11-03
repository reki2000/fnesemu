import 'dart:typed_data';

import 'package:fnesemu_core/src/core/pce/pce.dart';
import 'package:fnesemu_core/src/util/state.dart';
import 'package:test/test.dart';

/// A HuCard whose program maps the hardware and work RAM pages with TAM, sets up the VDC, enables the PSG noise channel and the timer, then counts in the zero page under VBlank and timer interrupts.
Uint8List _rom() {
  final rom = Uint8List(0x40000);
  const code = [
    0xa9, 0xff, 0x53, 0x01, // LDA #$ff; TAM #1 (MPR0 = hardware page)
    0xa9, 0xf8, 0x53, 0x02, // LDA #$f8; TAM #2 (MPR1 = work RAM)
    0xa9, 0x00, 0x53, 0x10, // LDA #$00; TAM #16 (MPR4 = bank 0)
    0x03, 0x05, 0x13, 0xc8, 0x23, 0x00, // ST0 #5; ST1 #$c8; ST2 #0 (BG, sprites, VBlank IRQ)
    0x03, 0x07, 0x13, 0x34, 0x23, 0x01, // ST0 #7; ST1 #$34; ST2 #1 (scroll X = $134)
    0xa9, 0x40, 0x8d, 0x00, 0x0c, // LDA #$40; STA $0c00 (timer reload)
    0xa9, 0x01, 0x8d, 0x01, 0x0c, // LDA #$01; STA $0c01 (timer on)
    0xa9, 0x05, 0x8d, 0x00, 0x08, // LDA #$05; STA $0800 (PSG channel 5)
    0xa9, 0xff, 0x8d, 0x04, 0x08, // LDA #$ff; STA $0804 (channel on, full volume)
    0xa9, 0xe3, 0x8d, 0x07, 0x08, // LDA #$e3; STA $0807 (noise on)
    0xa9, 0x88, 0x8d, 0x01, 0x08, // LDA #$88; STA $0801 (main amplitude)
    0x58, // CLI
    0xe6, 0x10, // loop: INC $10
    0xa5, 0x10, // LDA $10
    0x8d, 0x00, 0x08, // STA $0800 (keep selecting channels by the count)
    0x80, 0xf7, // BRA loop
  ];
  rom.setRange(0, code.length, code);
  // The reset vector at bank 0 offset $1ffe points at $e000, where bank 0 is mapped at reset.
  rom[0x1ffe] = 0x00;
  rom[0x1fff] = 0xe0;
  // The IRQ1 vector at $fff8 points at $e100: read the VDC status, then RTI.
  rom[0x1ff8] = 0x00;
  rom[0x1ff9] = 0xe1;
  rom.setRange(0x100, 0x104, [0xad, 0x00, 0x00, 0x40]);
  return rom;
}

Pce _system() => Pce()..setRom(_rom());

void _frames(Pce pce, int count) {
  for (var i = 0; i < count; i++) {
    expect(pce.runFrame(pce.scanlinesInFrame).stopped, isFalse);
  }
}

void main() {
  test('PCE restores into a fresh instance and continues identically', () {
    final original = _system();
    _frames(original, 2);
    expect(original.cpu.regs.mpr[0], 0xff);
    expect(original.cpu.regs.mpr[1], 0xf8);
    expect(original.bus.ram[0][0x10], isNonZero);
    final state = original.saveState();

    final restored = _system();
    final ram = restored.bus.ram, vram = restored.vdc.vram;
    restored.loadState(state);
    expect(restored.saveState(), state);
    expect(restored.bus.ram, same(ram));
    expect(restored.vdc.vram, same(vram));
    expect(restored.cpu.regs.mpr, original.cpu.regs.mpr);
    expect(restored.vdc2.colorTable, same(restored.vdc.colorTable));

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

  test('a state of different media fails before mutation', () {
    final original = _system();
    _frames(original, 1);
    final state = original.saveState();
    final otherRom = _rom();
    otherRom[0x2000] ^= 0xff;
    final other = Pce()..setRom(otherRom);
    _frames(other, 1);
    final before = other.saveState();
    expect(() => other.loadState(state), throwsA(isA<StateMismatch>()));
    expect(other.saveState(), before);
  });
}
