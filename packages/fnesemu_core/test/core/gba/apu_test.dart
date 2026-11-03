import 'package:fnesemu_core/src/core/gba/bus.dart';
import 'package:fnesemu_core/src/util/int.dart';
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

  });

}
