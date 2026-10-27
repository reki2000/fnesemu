import 'dart:typed_data';

import 'bus.dart';
import 'dmac.dart';
import 'gif.dart';
import 'gs/gs.dart';
import 'intc.dart';
import 'quad_fifo.dart';
import 'timer.dart';
import 'vif.dart';
import 'vu.dart';

/// The EE internal registers in the 0x10000000 range: timers, INTC and DMAC.
class EeIo implements IoPort {
  final Intc intc = Intc();
  late final EeTimers timers = EeTimers(intc);
  final Dmac dmac;
  final Gs gs = Gs();
  late final Gif gif = Gif(gs);
  final Vu vu0 = Vu(0), vu1 = Vu(1);
  late final Vif vif0 = Vif(0, vu0);
  late final Vif vif1 = Vif(1, vu1, path2: gif.path2, gs: gs);

  EeIo(Ps2Bus bus) : dmac = Dmac(bus) {
    gs.onInterrupt = () => intc.raise(Intc.gs);
    dmac.endpoints[Dmac.gif] = gif.path3;
    dmac.endpoints[Dmac.vif0] = vif0;
    dmac.endpoints[Dmac.vif1] = vif1;
    vu1.onXgkick = _xgkick;
    vu0.onCmsar1 = vu1.start;
  }

  /// Sends the packet at [quad] of VU1 data memory to the GIF (PATH1) up to
  /// the tag with EOP set.
  void _xgkick(int quad) {
    final path = gif.path1..reset();
    var q = quad;
    for (var n = 0; n < vu1.dataQuads; n++) {
      final w = q * 4;
      path.put(vu1.data[w] | (vu1.data[w + 1] << 32),
          vu1.data[w + 2] | (vu1.data[w + 3] << 32));
      q = (q + 1) & (vu1.dataQuads - 1);
      if (!path.busy && path.lastEop) break;
    }
  }

  static bool _isVif(int address) =>
      address >= 0x10003800 && address < 0x10004000;
  static bool _isVifFifo(int address) =>
      address >= 0x10004000 && address < 0x10006000;
  static bool _isVuMemory(int address) =>
      address >= 0x11000000 && address < 0x11010000;

  /// the VU memory a physical address falls in, and the offset inside it
  (Uint32List, int)? _vuMemory(int address) {
    if (address < 0x11001000) return (vu0.micro, address - 0x11000000);
    if (address >= 0x11004000 && address < 0x11005000) {
      return (vu0.data, address - 0x11004000);
    }
    if (address >= 0x11008000 && address < 0x1100c000) {
      return (vu1.micro, address - 0x11008000);
    }
    if (address >= 0x1100c000) return (vu1.data, address - 0x1100c000);
    return null;
  }

  final _vifFifo = QuadFifo();

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
    if (_isVif(address)) {
      return (address < 0x10003c00 ? vif0 : vif1).read(address & 0x3ff);
    }
    if (_isVuMemory(address)) {
      final m = _vuMemory(address);
      if (m == null) return 0;
      final (words, offset) = m;
      final i = offset >> 2;
      if (size == 8) return words[i] | (words[i + 1] << 32);
      return words[i];
    }
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
    } else if (_isVif(address)) {
      (address < 0x10003c00 ? vif0 : vif1).write(address & 0x3ff, value);
    } else if (_isVifFifo(address)) {
      if (_vifFifo.write(address, size, value)) {
        (address < 0x10005000 ? vif0 : vif1).put(_vifFifo.low, _vifFifo.high);
      }
    } else if (_isVuMemory(address)) {
      final m = _vuMemory(address);
      if (m == null) return false;
      final (words, offset) = m;
      final i = offset >> 2;
      words[i] = value;
      if (size == 8) words[i + 1] = value >>> 32;
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
      Gif.handles(address) ||
      _isVif(address) ||
      _isVifFifo(address) ||
      (_isVuMemory(address) && _vuMemory(address) != null);
}
