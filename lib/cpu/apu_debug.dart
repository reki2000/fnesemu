// Project imports:
import 'apu.dart';
import 'util.dart';

extension ApuDebugger on Apu {
  String dump() {
    return "apu irq:${frameIRQHold ? '*' : '-'} mode:${frameCounterMode0 ? '*' : '-'} "
        "0:${pulse0.enabled ? '*' : ' '} ${hex8(pulse0.lengthCounter)} ${hex8(pulse0.envelope.volume)} "
        "1:${pulse1.enabled ? '*' : ' '} ${hex8(pulse1.lengthCounter)} ${hex8(pulse1.envelope.volume)} "
        "t:${triangle.enabled ? '*' : ' '} ${hex8(triangle.lengthCounter)} "
        "n:${noise.enabled ? '*' : ' '} ${hex8(noise.lengthCounter)} ${hex8(pulse0.envelope.volume)} "
        "d:${dpcmEnabled ? '*' : ' '}";
  }
}
