import 'bus.dart';
import 'dmac.dart';
import 'intc.dart';
import 'timer.dart';

/// The EE internal registers in the 0x10000000 range: timers, INTC and DMAC.
class EeIo implements IoPort {
  final Intc intc = Intc();
  late final EeTimers timers = EeTimers(intc);
  final Dmac dmac;

  EeIo(Ps2Bus bus) : dmac = Dmac(bus);

  @override
  int read(int address, int size) {
    if (EeTimers.handles(address)) return timers.read(address);
    if (address == Intc.statAddress || address == Intc.maskAddress) {
      return intc.read(address);
    }
    if (Dmac.handles(address)) return dmac.read(address);
    return 0;
  }

  @override
  bool write(int address, int size, int value) {
    if (EeTimers.handles(address)) {
      timers.write(address, value);
    } else if (address == Intc.statAddress || address == Intc.maskAddress) {
      intc.write(address, value);
    } else if (Dmac.handles(address)) {
      dmac.write(address, value);
    } else {
      return false;
    }
    return true;
  }

  @override
  bool handles(int address) =>
      EeTimers.handles(address) ||
      address == Intc.statAddress ||
      address == Intc.maskAddress ||
      Dmac.handles(address);
}
