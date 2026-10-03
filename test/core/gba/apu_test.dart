import 'package:fnesemu/core/gba/bus.dart';
import 'package:test/test.dart';

void main() {
  group('Apu Direct Sound', () {
    test('timer overflow latches a FIFO byte as the DS level', () {
      final bus = Bus();
      final apu = bus.apu;

      // master enable + DS A on both sides, full volume, timer 0.
      bus.write16(0x04000084, 0x0080); // SOUNDCNT_X master enable
      bus.write16(0x04000082, 0x0304); // DS A: vol100% (bit2), L/R (bit8,9)

      // push a positive sample to FIFO A.
      bus.write32(0x040000a0, 0x00000040); // first byte = 0x40 (+64)

      // timer 0 overflow pops one byte.
      apu.onTimerOverflow(0, 1);

      final out = apu.render(4);
      // 0x40/128 = 0.5 on both channels.
      expect(out[0], closeTo(0.5, 0.001));
      expect(out[1], closeTo(0.5, 0.001));
    });

    test('draining the FIFO triggers a sound DMA refill', () {
      final bus = Bus();
      final apu = bus.apu;

      // place 16 source bytes in EWRAM for the DMA to copy.
      for (int i = 0; i < 16; i++) {
        bus.write8(0x02000000 + i, 0x10 + i);
      }

      // DMA1 -> FIFO A: src=EWRAM, dst=FIFO_A, special timing, repeat, 32-bit.
      bus.write32(0x040000bc, 0x02000000); // DMA1 SAD
      bus.write32(0x040000c0, 0x040000a0); // DMA1 DAD
      // CNT_H: enable(15) | special timing(12-13=3) | 32bit(10) | repeat(9)
      bus.write16(0x040000c6, 0x8000 | 0x3000 | 0x0400 | 0x0200);

      // First overflow: FIFO is empty (level stays 0) but it requests a refill
      // of four 32-bit words (16 bytes).
      apu.onTimerOverflow(0, 1);
      // Second overflow pops the first refilled byte (0x10).
      apu.onTimerOverflow(0, 1);

      // enable master + DS A so we can observe the latched level.
      bus.write16(0x04000084, 0x0080);
      bus.write16(0x04000082, 0x0304);

      final out = apu.render(1);
      expect(out[0], closeTo(0x10 / 128, 0.001));
    });
  });
}
