import 'dart:typed_data';

import 'bus.dart';
import 'dmac.dart';
import 'gif.dart';
import 'gs/gs.dart';
import 'intc.dart';
import 'iop/cdvd.dart';
import 'ipu/ipu.dart';
import 'quad_fifo.dart';
import 'sif.dart';
import 'state.dart';
import 'timer.dart';
import 'vif.dart';
import 'vu.dart';

/// The EE internal registers in the 0x10000000 range: timers, INTC and DMAC.
class EeIo implements IoPort {
  final Intc intc = Intc();
  late final EeTimers timers = EeTimers(intc);
  final Dmac dmac;
  final Gs gs = Gs();
  final Ipu ipu = Ipu();
  late final Gif gif = Gif(gs);
  final Sif sif = Sif();
  final Vu vu0 = Vu(0), vu1 = Vu(1);
  late final Vif vif0 = Vif(0, vu0);
  late final Vif vif1 = Vif(1, vu1, path2: gif.path2, gs: gs);

  EeIo(Ps2Bus bus) : dmac = Dmac(bus) {
    gs.onInterrupt = () => intc.raise(Intc.gs);
    dmac.endpoints[Dmac.gif] = gif.path3;
    dmac.endpoints[Dmac.vif0] = vif0;
    dmac.endpoints[Dmac.vif1] = vif1;
    vif1.path3Busy = () => dmac.path3Busy;
    dmac.onPath3Idle = () {
      vif1.resume();
      dmac.serviceChannel(Dmac.vif1);
    };
    vif0
      ..onInterrupt = (() => intc.raise(Intc.vif0))
      ..onResume = (() => dmac.serviceChannel(Dmac.vif0));
    vif1
      ..onInterrupt = (() => intc.raise(Intc.vif1))
      ..onResume = (() => dmac.serviceChannel(Dmac.vif1))
      ..onMaskPath3 = gif.maskPath3;
    gif.onPath3Resume = () => dmac.serviceChannel(Dmac.gif);
    sif.onEeInterrupt = () {
      timers.latchHold();
      intc.raise(Intc.sbus);
    };
    dmac.endpoints[Dmac.sif0] = sif.sif0;
    dmac.endpoints[Dmac.sif1] = sif.sif1;
    ipu
      ..onInterrupt = (() => intc.raise(Intc.ipu))
      ..onDma = dmac.serviceIpu;
    dmac.endpoints[Dmac.toIpu] = ipu.toIpu;
    dmac.endpoints[Dmac.fromIpu] = ipu.fromIpu;
    vu1.onXgkick = _xgkick;
    vu0.onCmsar1 = vu1.start;
  }

  /// Saves the EE devices. The CDVD and the IOP RAM belong to the IOP side.
  void saveState(StateWriter w) {
    w.section('ee io');
    intc.saveState(w);
    timers.saveState(w);
    dmac.saveState(w);
    gs.saveState(w);
    ipu.saveState(w);
    gif.saveState(w);
    sif.saveState(w);
    vu0.saveState(w);
    vu1.saveState(w);
    vif0.saveState(w);
    vif1.saveState(w);
    _vifFifo.saveState(w);
    w.ints([
      for (final e in _sys.entries) ...[e.key, e.value]
    ]);
    for (final d in _rdram) {
      w.ints([
        for (final e in d.entries) ...[e.key, e.value]
      ]);
    }
  }

  void loadState(StateReader s) {
    s.section('ee io');
    intc.loadState(s);
    timers.loadState(s);
    dmac.loadState(s);
    gs.loadState(s);
    ipu.loadState(s);
    gif.loadState(s);
    sif.loadState(s);
    vu0.loadState(s);
    vu1.loadState(s);
    vif0.loadState(s);
    vif1.loadState(s);
    _vifFifo.loadState(s);
    void map(Map<int, int> m) {
      final v = s.ints();
      m.clear();
      for (var i = 0; i + 1 < v.length; i += 2) {
        m[v[i]] = v[i + 1];
      }
    }

    map(_sys);
    _rdram.forEach(map);
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

  /// system registers (SIO, memory controller, ...): read back as written
  static bool _isSys(int address) =>
      address >= 0x1000f000 && address < 0x10010000 ||
      address >= 0x1a000000 && address < 0x1a010000 || // DEV9
      address >= 0x1f801400 && address < 0x1f801500 ||
      address >= 0x1f803800 && address < 0x1f803900;

  /// IOP RAM, which the EE sees at 0x1c000000
  Uint8List? iopRam;

  /// the CDVD controller, whose registers the EE also sees at 0x1f402000.
  /// The BIOS browser reads the disc type there.
  Cdvd? cdvd;

  bool _isCdvd(int address) => cdvd != null && Cdvd.handles(address);

  bool _isIopRam(int address) =>
      iopRam != null && address >= 0x1c000000 && address < 0x1c200000;

  int _iopRamRead(int address, int size) {
    final ram = iopRam!;
    final o = address - 0x1c000000;
    var v = 0;
    for (var i = size - 1; i >= 0; i--) {
      v = (v << 8) | ram[o + i];
    }
    return v;
  }

  void _iopRamWrite(int address, int size, int value) {
    final ram = iopRam!;
    final o = address - 0x1c000000;
    for (var i = 0; i < size; i++) {
      ram[o + i] = value & 0xff;
      value >>>= 8;
    }
  }

  final _sys = <int, int>{};

  int _sysRead(int address) {
    final v = _sys[address] ?? 0;
    // the memory controller command registers finish at once: busy bit 31
    // reads back clear
    return address == 0x1000f430 || address == 0x1000f410 ? v & 0x7fffffff : v;
  }

  /// RDRAM devices behind MCH_RICM/MCH_DRD. Each holds registers keyed by
  /// the register number of the command; register 0x21 (INIT) low 6 bits are
  /// the device id, 0x1f before an id is assigned. A command whose low 6 bits
  /// match a device id reaches the first such device in the chain, and any
  /// other value is broadcast. This is an unverified model of the init
  /// sequence the BIOS performs.
  static const _rdramDevices = 2;
  final _rdram = List.generate(_rdramDevices, (_) => <int, int>{0x21: 0x1f});

  void _sysWrite(int address, int value) {
    _sys[address] = value;
    if (address != 0x1000f430) return;
    final reg = (value >> 16) & 0xfff;
    final target = value & 0x3f;
    final matches = [
      for (final d in _rdram)
        if ((d[0x21]! & 0x3f) == target) d
    ];
    final reach = matches.isEmpty ? _rdram : [matches.first];
    final isRead = value >>> 28 == 0xb;
    if (isRead) {
      _sys[0x1000f440] = matches.isEmpty ? 0 : (matches.first[reg] ?? 0);
    } else {
      for (final d in reach) {
        d[reg] = _sys[0x1000f440] ?? 0;
      }
    }
  }

  static bool _isSif(int address) =>
      address >= 0x1000f200 && address < 0x1000f280;
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

  /// true for the 32-bit registers that byte and halfword accesses reach
  /// as a part of the aligned word
  static bool _isWordRegister(int address) =>
      EeTimers.handles(address) ||
      address & ~3 == Intc.statAddress ||
      address & ~3 == Intc.maskAddress ||
      Dmac.handles(address & ~3) ||
      address >= 0x10003000 && address < 0x10003100 ||
      _isVif(address) ||
      _isSif(address);

  /// registers where a written 1 clears or toggles a bit, so the bytes that
  /// a narrow write does not cover are written as zeros
  static bool _isClearOnWrite(int address) =>
      address == Intc.statAddress ||
      address == Intc.maskAddress ||
      address == 0x1000e010;

  @override
  int read(int address, int size) {
    if (address & 3 != 0 && size < 4 && _isWordRegister(address)) {
      return _readRegister(address & ~3) >>> ((address & 3) * 8);
    }
    if (_isGs(address) && address & 7 != 0) {
      return gs.readPrivileged(address & ~7) >>> ((address & 7) * 8);
    }
    return _readRegister(address, size);
  }

  int _readRegister(int address, [int size = 4]) {
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
    if (_isSif(address)) return sif.eeRead(address & 0xff);
    if (Ipu.handlesRegister(address)) return ipu.read(address, size);
    if (Ipu.handlesFifo(address)) return ipu.readFifo(address, size);
    if (_isVuMemory(address)) {
      final m = _vuMemory(address);
      if (m == null) return 0;
      final (words, offset) = m;
      final i = offset >> 2;
      if (size == 8) return words[i] | (words[i + 1] << 32);
      return words[i];
    }
    if (_isIopRam(address)) return _iopRamRead(address, size);
    if (_isCdvd(address)) return cdvd!.read(address);
    if (_isSys(address)) return _sysRead(address);
    return 0;
  }

  @override
  bool write(int address, int size, int value) {
    if (size < 4 && _isWordRegister(address)) {
      final aligned = address & ~3;
      final shift = (address & 3) * 8;
      final mask = (size == 1 ? 0xff : 0xffff) << shift;
      final old = _isClearOnWrite(aligned) ? 0 : _readRegister(aligned);
      return _writeRegister(
          aligned, 4, (old & ~mask) | ((value << shift) & mask));
    }
    if (_isGs(address) && size < 8) {
      // the privileged registers are 64 bits wide; CSR bits clear on a 1
      final aligned = address & ~7;
      final shift = (address & 7) * 8;
      final mask = (size == 4 ? 0xffffffff : (1 << size * 8) - 1) << shift;
      final old = aligned & 0x1fff == 0x1000 ? 0 : gs.readPrivileged(aligned);
      gs.writePrivileged(aligned, (old & ~mask) | ((value << shift) & mask));
      return true;
    }
    return _writeRegister(address, size, value);
  }

  bool _writeRegister(int address, int size, int value) {
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
    } else if (_isSif(address)) {
      sif.eeWrite(address & 0xff, value);
    } else if (Ipu.handlesRegister(address)) {
      ipu.write(address, size, value);
    } else if (Ipu.handlesFifo(address)) {
      ipu.writeFifo(address, size, value);
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
    } else if (_isIopRam(address)) {
      _iopRamWrite(address, size, value);
    } else if (_isCdvd(address)) {
      cdvd!.write(address, value);
    } else if (_isSys(address)) {
      _sysWrite(address, value);
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
      _isSif(address) ||
      Ipu.handlesRegister(address) ||
      Ipu.handlesFifo(address) ||
      _isSys(address) ||
      _isIopRam(address) ||
      _isCdvd(address) ||
      _isVif(address) ||
      _isVifFifo(address) ||
      (_isVuMemory(address) && _vuMemory(address) != null);
}
