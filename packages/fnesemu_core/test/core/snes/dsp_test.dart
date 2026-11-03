import 'package:fnesemu_core/src/core/snes/component/dsp.dart';
import 'package:fnesemu_core/src/core/snes/component/spc700.dart';
import 'package:fnesemu_core/src/util/int.dart';
import 'package:test/test.dart';

void main() {
  group('dsp', () {
    // voice 0 plays source 0: a single end+loop BRR block at $0300 that
    // loops back to $0400. directory at $0200.
    Dsp setup() {
      final dsp = Dsp();
      final snd = Spc700(dsp);
      snd.ram.setAll(0x200, [0x00, 0x03, 0x00, 0x04]);
      snd.ram[0x300] = 0xc3; // shift 12, filter 0, loop + end
      snd.ram.fillRange(0x301, 0x309, 0x11);
      snd.ram[0x400] = 0xc0;
      snd.ram.fillRange(0x401, 0x409, 0x11);
      dsp.write(0x5d, 0x02); // DIR
      dsp.write(0x6c, 0x00); // FLG: no reset / mute
      dsp.write(0x0c, 0x7f); // main volume
      dsp.write(0x1c, 0x7f);
      dsp.write(0x00, 0x7f); // voice 0 volume
      dsp.write(0x01, 0x7f);
      dsp.write(0x03, 0x10); // pitch 0x1000
      return dsp;
    }

    test('KON starts a voice and an end block continues at the loop point', () {
      final dsp = setup();
      dsp.write(0x05, 0x8f); // ADSR, fastest attack
      dsp.write(0x4c, 0x01); // KON
      expect(dsp.voices[0].envMode, isNot(EnvMode.off));

      dsp.mixSample();
      expect(dsp.voices[0].brrAddr, 0x400);
      expect(dsp.endx.mask1, 1);
      expect(dsp.voices[0].envMode, isNot(EnvMode.off));
    });

  });
}
