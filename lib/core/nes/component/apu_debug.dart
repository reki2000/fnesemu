// Project imports:
import '../../../util.dart';
import 'apu.dart';

extension ApuDebugger on Apu {
  String dump() {
    return "apu: irq:${frameIrqEnabled ? '*' : '-'} mode:${frameCounterMode0 ? '0' : '1'} "
        "0:${pulse0.enabled ? '*' : '-'} ${hex8(pulse0.lengthCounter)} ${hex8(pulse0.envelope.volume)} ${pulse0.sweep.debug()} "
        "1:${pulse1.enabled ? '*' : '-'} ${hex8(pulse1.lengthCounter)} ${hex8(pulse1.envelope.volume)} ${pulse1.sweep.debug()} "
        "t:${triangle.enabled ? '*' : '-'} ${hex8(triangle.lengthCounter)} "
        "n:${noise.enabled ? '*' : '-'} ${hex8(noise.lengthCounter)} ${hex8(pulse0.envelope.volume)} "
        "d:${dpcm.enabled ? '*' : '-'} ${hex8(noise.length)}"
        "\n";
  }
}
