import 'bus.dart';
import 'dmac.dart';
import 'gif.dart';
import 'gs/gs.dart';
import 'intc.dart';
import 'timer.dart';

/// The EE internal registers in the 0x10000000 range: timers, INTC and DMAC.
class EeIo implements IoPort {
  final Intc intc = Intc();
  late final EeTimers timers = EeTimers(intc);
  final Dmac dmac;
  final Gs gs = Gs();
  late final Gif gif = Gif(gs);

  EeIo(Ps2Bus bus) : dmac = Dmac(bus) {
    gs.onInterrupt = () => intc.raise(Intc.gs);
    dmac.endpoints[Dmac.gif] = gif.path3;
  }

  static bool _isGs(int address) =>
      address >= 0x12000000 && address < 0x12002000;

  @override
  int read(int address, int size) {
    if (EeTimers.handles(address)) return timers.read(address);
    if (address == Intc.statAddress || address == Intc.maskAddress) {
      return intc.read(address);
    }
    if (Dmac.handles(address)) return dmac.read(address);
    if (_isGs(address)) return gs.readPrivileged(address);
    if (Gif.handles(address)) return gif.read(address);
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
    } else if (_isGs(address)) {
      gs.writePrivileged(address, value);
    } else if (Gif.handles(address)) {
      gif.write(address, size, value);
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
      Dmac.handles(address) ||
      _isGs(address) ||
      Gif.handles(address);
}
