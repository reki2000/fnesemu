import 'package:fnesemu/util/int.dart';

import 'spu.dart';

class ReverbUint {
  int addrL = 0;
  int addrR = 0;
  int volume = 0;
  int offset = 0;

  void reset() {
    addrL = 0;
    addrR = 0;
    volume = 0;
    offset = 0;
  }
}

class Reverb {
  final Spu spu;
  Reverb(this.spu);

  void reset() {
    for (final e in [...apf, ...comb, ...ssr, ...dsr]) {
      e.reset();
    }

    workAddr = 0;
    setReverbEnabled(0);
    inputVolume[0] = inputVolume[1] = 0x8000;
    outputVolume[0] = outputVolume[1] = 0x8000;
  }

  final apf = [ReverbUint(), ReverbUint()];
  final comb = [ReverbUint(), ReverbUint(), ReverbUint(), ReverbUint()];
  final ssr = [ReverbUint(), ReverbUint()];
  final dsr = [ReverbUint(), ReverbUint()];

  final reverbEnabled = List.filled(24, false);
  final inputVolume = [0, 0];
  final outputVolume = [0, 0];

  int workAddr = 0;
  bool writeEnabled = false;

  (double, double) render(double inL, double inR) {
    final (l, r) =
        (inL * inputVolume[0] / 0x8000, inR * inputVolume[1] / 0x8000);
    final (outL, outR) =
        (l * outputVolume[0] / 0x8000, r * outputVolume[1] / 0x8000);
    return (outL, outR);
  }

  void setOutputVolume(int lr, int value) {
    outputVolume[lr & 1] = value.rel16;
  }

  void setReverbEnabled(int value) {
    for (int i = 0; i < reverbEnabled.length; i++, value >>= 1) {
      reverbEnabled[i] = value.bit0;
    }
  }

  void write16(int offset, int value) => switch (offset & 0x3f >> 1) {
        0x00 => apf[0].offset = value.rel16,
        0x01 => apf[1].offset = value.rel16,
        0x02 => ssr[0].volume = dsr[0].volume = value.rel16,
        0x03 => comb[0].volume = value.rel16,
        0x04 => comb[1].volume = value.rel16,
        0x05 => comb[2].volume = value.rel16,
        0x06 => comb[3].volume = value.rel16,
        0x07 => ssr[0].volume = dsr[0].volume = value.rel16,
        0x08 => apf[0].volume = value.rel16,
        0x09 => apf[1].volume = value.rel16,
        0x0a => ssr[0].addrL = value,
        0x0b => ssr[0].addrR = value,
        0x0c => comb[0].addrL = value,
        0x0d => comb[0].addrR = value,
        0x0e => comb[1].addrL = value,
        0x0f => comb[1].addrR = value,
        0x10 => ssr[1].addrL = value,
        0x11 => ssr[1].addrR = value,
        0x12 => dsr[0].addrL = value,
        0x13 => dsr[0].addrR = value,
        0x14 => comb[2].addrL = value,
        0x15 => comb[2].addrR = value,
        0x16 => comb[3].addrL = value,
        0x17 => comb[3].addrR = value,
        0x18 => dsr[1].addrL = value,
        0x19 => dsr[1].addrR = value,
        0x1a => apf[0].addrL = value,
        0x1b => apf[0].addrR = value,
        0x1c => apf[1].addrL = value,
        0x1d => apf[1].addrR = value,
        0x1e => inputVolume[0] = value.rel16,
        0x1f => inputVolume[1] = value.rel16,
        _ => throw "spu: reverb: unreachable offset:${offset.hex32}",
      };
}
