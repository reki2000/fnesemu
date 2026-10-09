import 'dart:math';
import 'dart:typed_data';

import 'package:fnesemu_core/core/pce/pce.dart';
import 'package:test/test.dart';

// a rom of random code (with a valid reset vector) that keeps the cpu busy,
// with the vdc showing bg and sprites and raising vblank irqs
Uint8List _rom() {
  final r = Random(3);
  final rom = Uint8List(0x40000);
  for (int i = 0; i < rom.length; i++) {
    rom[i] = r.nextInt(256);
  }
  // reset vector at bank 0's 0x1ffe: 0xe000 (bank 0 is mapped there at reset)
  rom[0x1ffe] = 0x00;
  rom[0x1fff] = 0xe0;
  // setup: map the hardware page to mpr0, enable bg/sprites/vblank irq,
  // then loop forever doing work ram writes
  const code = [
    0xa9, 0xff, 0x53, 0x01, // lda #$ff, tam #1
    0xa9, 0xf8, 0x53, 0x02, // lda #$f8, tam #2
    0x03, 0x05, 0x13, 0xc8, 0x23, 0x00, // st0 #5 st1 #$c8 st2 #0
    0x58, // cli
    0xe6, 0x10, 0xa5, 0x10, 0x8d, 0x00, 0x08, // inc $10 lda $10 sta $0800
    0x80, 0xf7, // bra (inc)
  ];
  rom.setRange(0, code.length, code);
  // irq1 vector (0xfff8): rti at 0xe100 after reading the vdc status
  rom[0x1ff8] = 0x00;
  rom[0x1ff9] = 0xe1;
  rom.setRange(0x100, 0x104, [0xad, 0x00, 0x00, 0x40]); // lda $0000 rti
  return rom;
}

void main() {
  test('runFrame gives the same result as exec until scanlines rendered', () {
    final a = Pce()..setRom(_rom());
    final b = Pce()..setRom(_rom());
    final audioA = <double>[];
    final audioB = <double>[];
    a.onAudio((buf) => audioA.addAll(buf.buffer));
    b.onAudio((buf) => audioB.addAll(buf.buffer));

    for (int frame = 0; frame < 30; frame++) {
      // uneven scanline counts, as the controller passes the rest of a frame
      final lines = frame == 0 ? 100 : 263;
      int n = 0;
      while (n < lines) {
        if (a.exec(false).scanlineRendered) n++;
      }
      final elapsedA = a.exec(false).elapsedClocks; // one more step
      final r = b.runFrame(lines);
      expect(r.stopped, isFalse);
      expect(r.scanlineRendered, isTrue);
      b.exec(false);
      expect(b.cpu.clocks, elapsedA);
      expect(b.cpu.regs.pc, a.cpu.regs.pc);
      expect(b.vdc.scanLine, a.vdc.scanLine);
    }
    expect(b.imageBuffer().buffer, a.imageBuffer().buffer);
    expect(audioB, audioA);
  });
}
