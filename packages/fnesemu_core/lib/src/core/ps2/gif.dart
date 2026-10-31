import 'dart:collection';

import 'dmac.dart';
import 'gs/gs.dart';
import 'quad_fifo.dart';
import 'state.dart';

/// One input path of the GIF (PATH1 from VU1, PATH2 from VIF1, PATH3 from
/// the DMA channel). Each path parses its own stream of GIF tags and writes
/// to the GS. The paths are not arbitrated: data of a path is processed as
/// soon as it arrives, so the intermittent mode of GIF_MODE has no effect.
///
/// Reading a tag sets the Q value of the GS to 1.0. A tag with NLOOP 0 is
/// ignored except for its EOP bit (ps2tek).
class GifPath extends DmaEndpoint {
  static const _packed = 0, _reglist = 1;

  final Gs gs;

  int _loops = 0; // NLOOP of the current tag
  int _flg = 0, _nreg = 0, _regs = 0;
  int _index = 0; // register inside the iteration
  int _dataLeft = 0; // quadwords or register values left in the tag

  GifPath(this.gs);

  /// true while the path is inside the data of a tag
  bool get busy => _dataLeft > 0;

  /// the EOP bit of the last tag
  bool lastEop = true;

  /// true between packets: after the data of a tag with EOP
  bool get betweenPackets => !busy && lastEop;

  /// called with every tag the path reads
  void Function(int low, int high)? onTag;

  /// the NLOOP count left in the current tag
  int get loopsLeft => switch (_flg) {
        _packed || _reglist => (_dataLeft + _nreg - 1) ~/ _nreg,
        _ => _dataLeft,
      };

  /// the register descriptor in progress
  int get regIndex => _index;

  void reset() {
    _dataLeft = 0;
    lastEop = true;
  }

  void saveState(StateWriter w) {
    w.ints([_loops, _flg, _nreg, _regs, _index, _dataLeft]);
    w.boolean(lastEop);
  }

  void loadState(StateReader s) {
    final v = s.fields(6, 'gif path');
    _loops = v[0];
    _flg = v[1];
    _nreg = v[2];
    _regs = v[3];
    _index = v[4];
    _dataLeft = v[5];
    lastEop = s.boolean();
  }

  /// With the tag transfer enable bit, only bits 64-127 of a DMA tag are
  /// transferred (ps2tek). The GIF takes whole quadwords, and what it does
  /// with that half is not documented. The DMA tag itself is never a GIF
  /// tag, so the path drops it.
  @override
  void putTag(int low, int high) {}

  @override
  void put(int low, int high) {
    if (_dataLeft == 0) {
      _tag(low, high);
      return;
    }
    switch (_flg) {
      case _packed:
        _packedQuad(low, high);
      case _reglist:
        _regValue(low);
        if (_dataLeft > 0) _regValue(high);
      default:
        gs.hostQuad(low, high);
        _dataLeft--;
    }
  }

  void _tag(int low, int high) {
    onTag?.call(low, high);
    _loops = low & 0x7fff;
    lastEop = (low >> 15) & 1 != 0;
    gs.setQ(0x3f800000);
    if (_loops == 0) return;
    _flg = (low >> 58) & 3;
    _nreg = (low >> 60) & 15;
    if (_nreg == 0) _nreg = 16;
    _regs = high;
    _index = 0;
    if (_flg <= _reglist && (low >> 46) & 1 != 0) {
      gs.writeRegister(0, (low >> 47) & 0x7ff);
    }
    _dataLeft = switch (_flg) {
      _packed => _loops * _nreg,
      _reglist => _loops * _nreg,
      _ => _loops,
    };
  }

  void _packedQuad(int low, int high) {
    final desc = (_regs >> (_index * 4)) & 15;
    if (++_index == _nreg) _index = 0;
    _dataLeft--;
    switch (desc) {
      case 0:
        gs.writeRegister(0, low & 0x7ff);
      case 1:
        gs.writeRegister(
            1,
            (low & 0xff) |
                (((low >> 32) & 0xff) << 8) |
                ((high & 0xff) << 16) |
                (((high >> 32) & 0xff) << 24) |
                (gs.qBits << 32));
      case 2:
        gs.writeRegister(2, low);
        gs.setQ(high);
      case 3:
        gs.writeRegister(3, (low & 0x3fff) | (((low >> 32) & 0x3fff) << 16));
      case 4 || 12:
        final adc = (high >> 47) & 1 != 0;
        final data = (low & 0xffff) |
            (((low >> 32) & 0xffff) << 16) |
            (((high >> 4) & 0xffffff) << 32) |
            (((high >> 36) & 0xff) << 56);
        gs.writeRegister(desc == 12 || adc ? 0x0c : 0x04, data);
      case 5 || 13:
        final adc = (high >> 47) & 1 != 0;
        final data = (low & 0xffff) |
            (((low >> 32) & 0xffff) << 16) |
            ((high & 0xffffffff) << 32);
        gs.writeRegister(desc == 13 || adc ? 0x0d : 0x05, data);
      case 6 || 7 || 8 || 9:
        gs.writeRegister(desc, low);
      case 10:
        gs.writeRegister(0x0a, ((high >> 36) & 0xff) << 56);
      case 14:
        gs.writeRegister(high & 0xff, low);
    }
  }

  void _regValue(int value) {
    final desc = (_regs >> (_index * 4)) & 15;
    if (++_index == _nreg) _index = 0;
    _dataLeft--;
    if (desc <= 0x0d && desc != 0x0b) gs.writeRegister(desc, value);
  }
}

/// PATH3 with the 16-quadword GIF FIFO. While PATH3 is masked by GIF_MODE or by MSKPATH3 of VIF1, the mask takes effect between packets, and the data that arrives stays in the FIFO until the mask is lifted. The DMA waits while the FIFO is full (ps2tek). The temporary stop of GIF_CTRL also holds the data. The hardware applies the GIF_MODE mask after the GIF DMA ends its transfer. Here every mask waits for the end of the packet.
class Path3 extends GifPath {
  static const fifoQuads = 16;

  /// true while PATH3 is masked or stopped
  final bool Function() masked;

  // the quadwords in the FIFO, as low and high halves
  final _fifo = ListQueue<int>();

  Path3(super.gs, this.masked);

  /// quadwords waiting in the FIFO
  int get queued => _fifo.length >> 1;

  bool get _holding => masked() && betweenPackets;

  @override
  bool get canPut => _fifo.isEmpty && !_holding || queued < fifoQuads;

  @override
  void put(int low, int high) {
    if (_fifo.isEmpty && !_holding) {
      super.put(low, high);
      return;
    }
    if (queued < fifoQuads) {
      _fifo
        ..add(low)
        ..add(high);
    }
  }

  /// sends the queued data on once the mask is lifted
  void drain() {
    while (_fifo.isNotEmpty && !_holding) {
      super.put(_fifo.removeFirst(), _fifo.removeFirst());
    }
  }

  @override
  void reset() {
    super.reset();
    _fifo.clear();
  }

  @override
  void saveState(StateWriter w) {
    super.saveState(w);
    w.ints(_fifo.toList());
  }

  @override
  void loadState(StateReader s) {
    super.loadState(s);
    _fifo
      ..clear()
      ..addAll(s.ints());
  }
}

/// The GIF registers and the three paths.
///
/// GIF_TAG0-3 return the last tag that any path read, and GIF_CNT the loop
/// counter of the last path that read a tag. The hardware makes them
/// readable only while the GIF is stopped by GIF_CTRL; here they are always
/// readable.
class Gif {
  static const _pse = 1 << 3;

  final Gs gs;
  late final path1 = GifPath(gs)..onTag = _tag(1);
  late final path2 = GifPath(gs)..onTag = _tag(2);
  late final path3 = Path3(gs, () => _path3Masked)..onTag = _tag(3);

  int ctrl = 0, mode = 0;

  /// the PATH3 mask that MSKPATH3 of VIF1 sets
  bool vifMask = false;

  /// called when PATH3 can take data again
  void Function()? onPath3Resume;

  int _tagLow = 0, _tagHigh = 0, _lastPath = 0;

  Gif(this.gs);

  bool get _path3Masked => mode & 1 != 0 || vifMask || ctrl & _pse != 0;

  void Function(int, int) _tag(int path) => (low, high) {
        _tagLow = low;
        _tagHigh = high;
        _lastPath = path;
      };

  /// sets the MSKPATH3 mask of VIF1
  void maskPath3(bool on) {
    vifMask = on;
    _resumePath3();
  }

  void _resumePath3() {
    path3.drain();
    if (path3.canPut) onPath3Resume?.call();
  }

  static bool handles(int address) =>
      address >= 0x10003000 && address < 0x10003100 ||
      address >= 0x10006000 && address < 0x10007000;

  GifPath? get _active => switch (_lastPath) {
        1 => path1,
        2 => path2,
        3 => path3,
        _ => null,
      };

  int read(int address) {
    return switch (address & 0xfff0) {
      0x3010 => mode,
      0x3020 => _stat,
      0x3040 => _tagLow & 0xffffffff,
      0x3050 => _tagLow >>> 32,
      0x3060 => _tagHigh & 0xffffffff,
      0x3070 => _tagHigh >>> 32,
      0x3080 => _active == null
          ? 0
          : (_active!.loopsLeft & 0x7fff) | (_active!.regIndex << 16),
      0x3090 => path3.loopsLeft & 0x7fff,
      0x30a0 => _lastPath == 3 ? _tagLow & 0xffffffff : 0,
      _ => 0,
    };
  }

  /// GIF_STAT. The paths are not arbitrated, so the active path is the one
  /// inside the data of a tag.
  int get _stat {
    final active = path1.busy
        ? 1
        : path2.busy
            ? 2
            : path3.busy
                ? 3
                : 0;
    return (mode & 1) |
        (vifMask ? 2 : 0) |
        (mode & 4) |
        (ctrl & _pse) |
        (path3.queued > 0 ? 1 << 6 : 0) |
        (active != 0 ? 1 << 9 : 0) |
        (active << 10) |
        (path3.queued << 24);
  }

  final _fifo = QuadFifo();

  void saveState(StateWriter w) {
    w.section('gif');
    w.ints([ctrl, mode, vifMask ? 1 : 0, _tagLow, _tagHigh, _lastPath]);
    for (final p in [path1, path2, path3]) {
      p.saveState(w);
    }
    _fifo.saveState(w);
  }

  void loadState(StateReader s) {
    s.section('gif');
    final v = s.fields(6, 'gif');
    ctrl = v[0];
    mode = v[1];
    vifMask = v[2] != 0;
    _tagLow = v[3];
    _tagHigh = v[4];
    _lastPath = v[5];
    for (final p in [path1, path2, path3]) {
      p.loadState(s);
    }
    _fifo.loadState(s);
  }

  /// returns true when [address] belongs to the GIF
  bool write(int address, int size, int value) {
    if (address >= 0x10006000) {
      if (_fifo.write(address, size, value)) {
        path3.put(_fifo.low, _fifo.high);
      }
      return true;
    }
    switch (address & 0xfff0) {
      case 0x3000:
        ctrl = value & _pse;
        if (value & 1 != 0) {
          path1.reset();
          path2.reset();
          path3.reset();
          vifMask = false;
          mode = 0;
        }
        _resumePath3();
      case 0x3010:
        mode = value & 5;
        _resumePath3();
    }
    return true;
  }
}
