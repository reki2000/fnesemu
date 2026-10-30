import 'dmac.dart';
import 'gs/gs.dart';
import 'quad_fifo.dart';
import 'state.dart';

/// One input path of the GIF (PATH1 from VU1, PATH2 from VIF1, PATH3 from
/// the DMA channel). Each path parses its own stream of GIF tags and writes
/// to the GS. The paths are not arbitrated: data of a path is processed as
/// soon as it arrives.
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
  bool lastEop = false;

  void reset() {
    _dataLeft = 0;
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
    _loops = low & 0x7fff;
    lastEop = (low >> 15) & 1 != 0;
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

/// The GIF registers and the three paths.
class Gif {
  final Gs gs;
  late final path1 = GifPath(gs);
  late final path2 = GifPath(gs);
  late final path3 = GifPath(gs);

  int ctrl = 0, mode = 0;

  Gif(this.gs);

  static bool handles(int address) =>
      address >= 0x10003000 && address < 0x10003100 ||
      address >= 0x10006000 && address < 0x10007000;

  int read(int address) {
    return switch (address & 0xfff0) {
      0x3010 => mode,
      0x3020 => 0, // GIF_STAT: idle
      _ => 0,
    };
  }

  final _fifo = QuadFifo();

  void saveState(StateWriter w) {
    w.section('gif');
    w.ints([ctrl, mode]);
    for (final p in [path1, path2, path3]) {
      p.saveState(w);
    }
    _fifo.saveState(w);
  }

  void loadState(StateReader s) {
    s.section('gif');
    final v = s.fields(2, 'gif');
    ctrl = v[0];
    mode = v[1];
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
        ctrl = value;
        if (value & 1 != 0) {
          path1.reset();
          path2.reset();
          path3.reset();
        }
      case 0x3010:
        mode = value;
    }
    return true;
  }
}
