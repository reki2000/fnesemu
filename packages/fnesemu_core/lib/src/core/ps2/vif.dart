import 'dart:collection';
import 'dart:typed_data';

import 'dmac.dart';
import 'gif.dart';
import 'gs/gs.dart';
import 'quad_fifo.dart';
import 'vu.dart';

/// A VPU interface (VIF0 for VU0, VIF1 for VU1). It decodes the VIFcode
/// stream that arrives through DMA or the FIFO window.
///
/// Not implemented: interrupts and stalls (the IRQ bit of a code), the
/// FLUSH family (micro programs finish when started), MSKPATH3, error
/// detection, and the write-cycle filling of UNPACK with CL < WL. VIF1
/// waits at FLUSHA while PATH3 transfers (see [path3Busy]).
class Vif extends DmaEndpoint {
  static const _mpg = 0x4a, _direct = 0x50, _directHl = 0x51;

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

  // words that arrived while the VIF waits at FLUSHA
  final _held = ListQueue<int>();
  bool _waiting = false;

  Vif(this.index, this.vu, {this.path2, this.gs}) {
    vu.top = () => top;
    vu.itop = () => itop;
  }

  void reset() {
    _held.clear();
    _waiting = false;
    _wordsLeft = 0;
    _count = 0;
    _quadCount = 0;
    stat = 0;
    cl = wl = 1;
    mode = 0;
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
  bool get canPut => !_waiting;

  /// continues after FLUSHA when PATH3 is idle
  void resume() {
    if (!_waiting || (path3Busy?.call() ?? false)) return;
    _waiting = false;
    while (!_waiting && _held.isNotEmpty) {
      _process(_held.removeFirst());
    }
  }

  void _word(int w) {
    if (_waiting || _held.isNotEmpty) {
      _held.add(w);
      return;
    }
    _process(w);
  }

  void _process(int w) {
    if (_wordsLeft == 0) {
      _decode(w);
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
    if (--_wordsLeft == 0) _finish();
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
      case 0x01:
        cl = _imm & 0xff;
        wl = (_imm >> 8) & 0xff;
      case 0x02:
        ofst = _imm & 0x3ff;
        tops = base;
      case 0x03:
        base = _imm & 0x3ff;
      case 0x04:
        itops = _imm & 0x3ff;
      case 0x05:
        mode = _imm & 3;
      case 0x07:
        mark = _imm;
      case 0x14 || 0x15:
        _startProgram(_imm);
      case 0x17:
        _startProgram(vu.pc);
      case 0x13: // FLUSHA
        _waiting = path3Busy?.call() ?? false;
      case 0x20:
        _expect(1);
      case 0x30 || 0x31:
        _expect(4);
      case _mpg:
        _expect((_num == 0 ? 256 : _num) * 2);
      case _direct || _directHl:
        _expect((_imm == 0 ? 65536 : _imm) * 4);
      default:
        if (_cmd & 0x60 == 0x60) _beginUnpack();
    }
  }

  void _startProgram(int address) {
    if (index == 1) {
      top = tops;
      tops = tops == base ? base + ofst : base;
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
    final vectors = _num == 0 ? 256 : _num;
    _expect((vectors * _bitsPerVector + 31) >> 5);
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
    final x = List<int>.filled(4, 0);
    for (var i = 0; i < vectors; i++) {
      final e = List<int>.generate(comps, (j) {
        final raw = _element(i, j, elementBits);
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
      final slot = i % writeCycle;
      final dest = addr + (i ~/ writeCycle) * cycle + slot;
      final j = slot > 3 ? 3 : slot;
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

  int read(int offset) {
    switch (offset & 0xff0) {
      case 0x000:
        return stat | (fdr ? 1 << 23 : 0);
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
        return 0;
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
      case 0x030:
        mark = value & 0xffff;
      case 0x100 || 0x110 || 0x120 || 0x130:
        row[(offset >> 4) & 3] = value;
      case 0x200 || 0x210 || 0x220 || 0x230:
        col[(offset >> 4) & 3] = value;
    }
  }
}
