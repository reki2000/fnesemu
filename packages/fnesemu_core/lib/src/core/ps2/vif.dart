import 'dart:collection';
import 'dart:typed_data';

import 'dmac.dart';
import 'gif.dart';
import 'gs/gs.dart';
import 'quad_fifo.dart';
import 'state.dart';
import 'vu.dart';

/// A VPU interface (VIF0 for VU0, VIF1 for VU1). It decodes the VIFcode
/// stream that arrives through DMA or the FIFO window.
///
/// A code with the interrupt bit raises the VIF interrupt after it executes, and the VIF stalls on the next code other than MARK until STC is written to FBRST (ps2tek). Bit 0 of ERR (MII) disables both. STP of FBRST stalls the VIF after the current code and FBK stalls it at once. An undefined code is skipped, and it stalls the VIF with ER1 unless bit 2 of ERR (ME1) is set. VIF0 skips the codes of VIF1 without an error. Whether an error raises the interrupt is not documented, so it does not. The DMA tag mismatch error (ER0) is not detected.
///
/// VIF1 waits at FLUSHA while PATH3 transfers (see [path3Busy]). The other waits of the FLUSH and MSCAL family are met at once, because a micro program runs to its end when it starts. DIRECTHL does not wait for an IMAGE transfer of PATH3, because the GIF paths are not arbitrated.
///
/// UNPACK with CL < WL (filling write) reads data for the first CL vectors of each WL and fills the rest. A filled vector takes the ROW or COL value its mask selects. The fields that would take data are left unchanged, which is unverified.
class Vif extends DmaEndpoint {
  static const _mpg = 0x4a, _direct = 0x50, _directHl = 0x51, _mark = 0x07;

  // STAT: VIS (stalled on an interrupt bit) and INT (interrupt bit seen)
  static const _vis = 1 << 10, _int = 1 << 11;
  static const _mrk = 1 << 6, _vss = 1 << 8, _vfs = 1 << 9, _er1 = 1 << 13;
  static const _stalls = _vss | _vfs | _vis | _er1;

  final int index;
  final Vu vu;
  final GifPath? path2;
  final Gs? gs;

  int stat = 0, fbrst = 0, err = 0, mark = 0, code = 0;
  int cl = 1, wl = 1, mode = 0, mask = 0;
  int itops = 0, base = 0, ofst = 0, tops = 0, itop = 0, top = 0;
  bool fdr = false;
  final row = Uint32List(4);
  final col = Uint32List(4);

  // decoding state
  int _wordsLeft = 0;
  int _cmd = 0, _num = 0, _imm = 0;
  final _buf = Uint32List(1024);
  int _count = 0;
  final _quadWords = Uint32List(4);
  int _quadCount = 0;

  final fifo = QuadFifo();

  /// true while PATH3 transfers; FLUSHA waits until it is false
  bool Function()? path3Busy;

  /// raised by the interrupt bit of a code
  void Function()? onInterrupt;

  /// called when a stall ends, so that DMA can send more data
  void Function()? onResume;

  /// VIF1 only: called by MSKPATH3 with the new mask
  void Function(bool on)? onMaskPath3;

  // words that arrived while the VIF waits at FLUSHA
  final _held = ListQueue<int>();
  bool _waiting = false;

  // STP was written and the VIF stalls after the current code
  bool _stop = false;

  // the double buffer flag: TOPS is BASE + OFST
  bool _dbf = false;

  Vif(this.index, this.vu, {this.path2, this.gs}) {
    vu.top = () => top;
    vu.itop = () => itop;
  }

  void reset() {
    _held.clear();
    _waiting = false;
    _stop = false;
    _wordsLeft = 0;
    _count = 0;
    _quadCount = 0;
    stat = 0;
    cl = wl = 1;
    mode = 0;
  }

  void saveState(StateWriter w) {
    w.section('vif$index');
    w.ints([
      stat, fbrst, err, mark, code, cl, wl, mode, mask, itops, base, ofst, //
      tops, itop, top, _wordsLeft, _cmd, _num, _imm, _count, _quadCount,
      _bitsPerVector,
    ]);
    w.boolean(fdr);
    w.boolean(_waiting);
    w.boolean(_stop);
    w.boolean(_dbf);
    for (final list in [row, col, _buf, _quadWords]) {
      w.typed(list);
    }
    fifo.saveState(w);
    w.ints(_held.toList());
  }

  void loadState(StateReader s) {
    s.section('vif$index');
    final v = s.fields(22, 'vif');
    stat = v[0];
    fbrst = v[1];
    err = v[2];
    mark = v[3];
    code = v[4];
    cl = v[5];
    wl = v[6];
    mode = v[7];
    mask = v[8];
    itops = v[9];
    base = v[10];
    ofst = v[11];
    tops = v[12];
    itop = v[13];
    top = v[14];
    _wordsLeft = v[15];
    _cmd = v[16];
    _num = v[17];
    _imm = v[18];
    _count = v[19];
    _quadCount = v[20];
    _bitsPerVector = v[21];
    fdr = s.boolean();
    _waiting = s.boolean();
    _stop = s.boolean();
    _dbf = s.boolean();
    for (final list in [row, col, _buf, _quadWords]) {
      s.typed(list);
    }
    fifo.loadState(s);
    _held
      ..clear()
      ..addAll(s.ints());
  }

  @override
  void put(int low, int high) {
    _word(low & 0xffffffff);
    _word(low >>> 32);
    _word(high & 0xffffffff);
    _word(high >>> 32);
  }

  /// the tag transfer sends only the upper half of the tag quadword, which
  /// holds two VIF codes
  @override
  void putTag(int low, int high) {
    _word(high & 0xffffffff);
    _word(high >>> 32);
  }

  @override
  void get(Int64List out) {
    if (index == 1 && fdr && gs != null) {
      gs!.readQuad(out);
    } else {
      out[0] = out[1] = 0;
    }
  }

  @override
  bool get canPut => !_waiting && !_stalled;

  bool get _stalled => stat & _stalls != 0;

  /// continues after FLUSHA when PATH3 is idle
  void resume() {
    if (!_waiting || (path3Busy?.call() ?? false)) return;
    _waiting = false;
    _drain();
  }

  void _drain() {
    while (!_waiting && !_stalled && _held.isNotEmpty) {
      _process(_held.removeFirst());
    }
  }

  void _word(int w) {
    if (_waiting || _stalled || _held.isNotEmpty) {
      _held.add(w);
      return;
    }
    _process(w);
  }

  void _process(int w) {
    if (_wordsLeft == 0) {
      if (stat & _int != 0 && (w >> 24) & 0x7f != _mark) {
        // the code after an interrupt bit waits for STC
        stat |= _vis;
        _held.addFirst(w);
        return;
      }
      _decode(w);
      if (_wordsLeft == 0) _done();
      return;
    }
    switch (_cmd) {
      case _direct || _directHl:
        _quadWords[_quadCount++] = w;
        if (_quadCount == 4) {
          _quadCount = 0;
          path2?.put(_quadWords[0] | (_quadWords[1] << 32),
              _quadWords[2] | (_quadWords[3] << 32));
        }
      default:
        _buf[_count++] = w;
    }
    if (--_wordsLeft == 0) {
      _finish();
      _done();
    }
  }

  /// ends a code: raises the interrupt of the interrupt bit and stalls for
  /// a STP that was written while the code ran
  void _done() {
    if (_stop) {
      _stop = false;
      stat |= _vss;
    }
    if (code >>> 31 == 0 || err & 1 != 0) return;
    stat |= _int;
    onInterrupt?.call();
  }

  void _expect(int words) {
    _wordsLeft = words;
    _count = 0;
    _quadCount = 0;
  }

  void _decode(int w) {
    code = w;
    _imm = w & 0xffff;
    _num = (w >> 16) & 0xff;
    _cmd = (w >> 24) & 0x7f;
    switch (_cmd) {
      case 0x00 || 0x10:
        break;
      case 0x01:
        cl = _imm & 0xff;
        wl = (_imm >> 8) & 0xff;
      case 0x04:
        itops = _imm & 0x3ff;
      case 0x05:
        mode = _imm & 3;
      case 0x07:
        mark = _imm;
        stat |= _mrk;
      case 0x14:
        _startProgram(_imm);
      case 0x17:
        _startProgram(vu.pc);
      case 0x02 when index == 1:
        ofst = _imm & 0x3ff;
        _dbf = false;
        tops = base;
      case 0x03 when index == 1:
        base = _imm & 0x3ff;
      case 0x06 when index == 1:
        onMaskPath3?.call((_imm >> 15) & 1 != 0);
      case 0x11 when index == 1:
        break;
      case 0x13 when index == 1: // FLUSHA
        _waiting = path3Busy?.call() ?? false;
      case 0x15 when index == 1:
        _startProgram(_imm);
      case 0x20:
        _expect(1);
      case 0x30 || 0x31:
        _expect(4);
      case _mpg:
        _expect((_num == 0 ? 256 : _num) * 2);
      case _direct || _directHl when index == 1:
        _expect((_imm == 0 ? 65536 : _imm) * 4);
      default:
        // UNPACK formats 3, 7 and 11 are undefined
        if (_cmd & 0x60 == 0x60 &&
            _cmd & 0xf != 3 &&
            _cmd & 0xf != 7 &&
            _cmd & 0xf != 11) {
          _beginUnpack();
        } else if (err & 4 == 0 && !(index == 0 && _vif1Only(_cmd))) {
          stat |= _er1;
        }
    }
  }

  /// the codes that only VIF1 defines; what VIF0 does with them is not
  /// documented, so it skips them without an error
  static bool _vif1Only(int cmd) => switch (cmd) {
        0x02 ||
        0x03 ||
        0x06 ||
        0x11 ||
        0x13 ||
        0x15 ||
        _direct ||
        _directHl =>
          true,
        _ => false,
      };

  void _startProgram(int address) {
    if (index == 1) {
      top = tops;
      _dbf = !_dbf;
      tops = _dbf ? base + ofst : base;
    }
    itop = itops;
    vu.start(address);
  }

  // ---- UNPACK ----

  int _bitsPerVector = 0;

  void _beginUnpack() {
    final fmt = _cmd & 0xf;
    final comps = ((fmt >> 2) & 3) + 1;
    final size = fmt & 3;
    _bitsPerVector = size == 3 ? 16 : comps * (32 >> size);
    _expect((_dataVectors() * _bitsPerVector + 31) >> 5);
  }

  /// the number of vectors that read data; a filling write reads only the
  /// first CL vectors of each WL
  int _dataVectors() {
    final vectors = _num == 0 ? 256 : _num;
    if (cl >= wl) return vectors;
    final full = vectors ~/ wl, rest = vectors % wl;
    return full * cl + (rest < cl ? rest : cl);
  }

  int _element(int vector, int j, int bits) {
    final pos = vector * _bitsPerVector + j * bits;
    final word = _buf[pos >> 5];
    final shift = pos & 31;
    if (bits == 32) return word;
    return (word >> shift) & ((1 << bits) - 1);
  }

  void _unpack() {
    final fmt = _cmd & 0xf;
    final comps = ((fmt >> 2) & 3) + 1;
    final size = fmt & 3;
    final unsigned = (_imm >> 14) & 1 != 0;
    var addr = _imm & 0x3ff;
    if ((_imm >> 15) & 1 != 0 && index == 1) addr += tops;
    final maskEnabled = _cmd & 0x10 != 0;
    final vectors = _num == 0 ? 256 : _num;
    final writeCycle = wl == 0 ? 1 : wl;
    final cycle = cl < writeCycle ? writeCycle : cl;
    final elementBits = size == 3 ? 16 : 32 >> size;
    final filling = cl < writeCycle;
    final x = List<int>.filled(4, 0);
    var k = 0;
    for (var i = 0; i < vectors; i++) {
      final slot = i % writeCycle;
      final dest = addr + (i ~/ writeCycle) * cycle + slot;
      final j = slot > 3 ? 3 : slot;
      if (filling && slot >= cl) {
        for (var c = 0; c < 4; c++) {
          final field = maskEnabled ? (mask >> (2 * (j * 4 + c))) & 3 : 0;
          final v = switch (field) { 1 => row[c], 2 => col[j], _ => null };
          if (v != null) vu.data[((dest & (vu.dataQuads - 1)) * 4) + c] = v;
        }
        continue;
      }
      final n = k++;
      final e = List<int>.generate(comps, (j) {
        final raw = _element(n, j, elementBits);
        if (size == 0) return raw;
        if (unsigned) return raw;
        return raw.toSigned(elementBits) & 0xffffffff;
      });
      if (size == 3) {
        final v = e[0];
        x[0] = (v & 31) << 3;
        x[1] = ((v >> 5) & 31) << 3;
        x[2] = ((v >> 10) & 31) << 3;
        x[3] = ((v >> 15) & 1) << 7;
      } else if (comps == 1) {
        x[0] = x[1] = x[2] = x[3] = e[0];
      } else {
        for (var c = 0; c < 4; c++) {
          x[c] = c < comps ? e[c] : 0;
        }
      }
      for (var c = 0; c < 4; c++) {
        final field = maskEnabled ? (mask >> (2 * (j * 4 + c))) & 3 : 0;
        int v;
        switch (field) {
          case 0:
            v = x[c];
            if (mode != 0) {
              v = (v + row[c]) & 0xffffffff;
              if (mode == 2) row[c] = v;
            }
          case 1:
            v = row[c];
          case 2:
            v = col[j];
          default:
            continue;
        }
        vu.data[((dest & (vu.dataQuads - 1)) * 4) + c] = v;
      }
    }
  }

  void _finish() {
    switch (_cmd) {
      case 0x20:
        mask = _buf[0];
      case 0x30:
        for (var c = 0; c < 4; c++) {
          row[c] = _buf[c];
        }
      case 0x31:
        for (var c = 0; c < 4; c++) {
          col[c] = _buf[c];
        }
      case _mpg:
        final n = _count;
        for (var k = 0; k < n; k++) {
          vu.micro[(_imm * 2 + k) & (vu.microWords - 1)] = _buf[k];
        }
      case _direct || _directHl:
        break;
      default:
        _unpack();
    }
  }

  // ---- registers ----

  /// the NUM register: the vectors or doublewords that UNPACK or MPG has not
  /// received yet
  int get _numLeft {
    if (_wordsLeft == 0) return 0;
    if (_cmd == _mpg) return ((_wordsLeft + 1) >> 1) & 0xff;
    if (_cmd & 0x60 != 0x60 || _bitsPerVector == 0) return 0;
    return ((_wordsLeft * 32 + _bitsPerVector - 1) ~/ _bitsPerVector) & 0xff;
  }

  int read(int offset) {
    switch (offset & 0xff0) {
      case 0x000:
        final fifoQuads = (_held.length + 3) >> 2;
        final limit = index == 0 ? 8 : 16;
        return stat |
            (_wordsLeft > 0 ? 1 : 0) |
            (_waiting ? 1 << 3 : 0) |
            (_dbf ? 1 << 7 : 0) |
            (fdr ? 1 << 23 : 0) |
            ((fifoQuads < limit ? fifoQuads : limit) << 24);
      case 0x010:
        return 0;
      case 0x020:
        return err;
      case 0x030:
        return mark;
      case 0x040:
        return cl | (wl << 8);
      case 0x050:
        return mode;
      case 0x060:
        return _numLeft;
      case 0x070:
        return mask;
      case 0x080:
        return code;
      case 0x090:
        return itops;
      case 0x0a0:
        return base;
      case 0x0b0:
        return ofst;
      case 0x0c0:
        return tops;
      case 0x0d0:
        return itop;
      case 0x0e0:
        return top;
      case 0x100 || 0x110 || 0x120 || 0x130:
        return row[(offset >> 4) & 3];
      case 0x200 || 0x210 || 0x220 || 0x230:
        return col[(offset >> 4) & 3];
    }
    return 0;
  }

  void write(int offset, int value) {
    switch (offset & 0xff0) {
      case 0x000:
        fdr = (value >> 23) & 1 != 0;
      case 0x010:
        if (value & 1 != 0) reset();
        fbrst = value;
        if (value & 2 != 0) stat |= _vfs;
        if (value & 4 != 0) {
          if (_wordsLeft == 0) {
            stat |= _vss;
          } else {
            _stop = true;
          }
        }
        if (value & 8 != 0) {
          // STC clears VSS, VFS, VIS, INT, ER0 and ER1
          stat &= ~0x3f00;
          _stop = false;
          _drain();
          onResume?.call();
        }
      case 0x020:
        err = value & 7;
      case 0x030:
        mark = value & 0xffff;
        stat &= ~_mrk;
      case 0x100 || 0x110 || 0x120 || 0x130:
        row[(offset >> 4) & 3] = value;
      case 0x200 || 0x210 || 0x220 || 0x230:
        col[(offset >> 4) & 3] = value;
    }
  }
}
