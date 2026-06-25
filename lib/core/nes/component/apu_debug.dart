import 'package:fnesemu/util/int.dart';
// Project imports:
import 'apu.dart';

extension ApuDebugger on Apu {
  String dump() {
    return "apu: irq:${frameIrqEnabled ? '*' : '-'} mode:${frameCounterMode0 ? '0' : '1'} "
        "0:${pulse0.enabled ? '*' : '-'} ${pulse0.lengthCounter.x2} ${pulse0.envelope.volume.x2} ${pulse0.sweep.debug()} "
        "1:${pulse1.enabled ? '*' : '-'} ${pulse1.lengthCounter.x2} ${pulse1.envelope.volume.x2} ${pulse1.sweep.debug()} "
        "t:${triangle.enabled ? '*' : '-'} ${triangle.lengthCounter.x2} "
        "n:${noise.enabled ? '*' : '-'} ${noise.lengthCounter.x2} ${pulse0.envelope.volume.x2} "
        "d:${dpcm.enabled ? '*' : '-'} ${noise.length.x2}"
        "\n";
  }
}
