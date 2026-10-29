import 'dart:typed_data';

import '../../../types.dart';
import 'gs_memory.dart';
import 'gs_raster.dart';

/// A vertex of the primitive being assembled.
class GsVertex {
  /// position in 12.4 fixed point before the offset is applied
  int x = 0, y = 0;
  int z = 0;
  int r = 0, g = 0, b = 0, a = 0;
  int f = 0;
  double s = 0, t = 0, q = 1;

  /// texel coordinates in 12.4 fixed point
  int u = 0, v = 0;

  void copyFrom(GsVertex o) {
    x = o.x;
    y = o.y;
    z = o.z;
    r = o.r;
    g = o.g;
    b = o.b;
    a = o.a;
    f = o.f;
    s = o.s;
    t = o.t;
    q = o.q;
    u = o.u;
    v = o.v;
  }
}

/// The registers that exist once per drawing context.
class GsContext {
  int tex0 = 0, tex1 = 0, clamp = 0, xyoffset = 0, scissor = 0;
  int alpha = 0, test = 0, fba = 0, frame = 0, zbuf = 0;
}

/// The Graphics Synthesizer: registers, transfers between host and local
/// memory, the vertex queue, and the output image. Drawing is done by
/// [GsRaster].
class Gs {
  static const primPoint = 0, primLine = 1, primLineStrip = 2;
  static const primTriangle = 3, primTriangleStrip = 4, primTriangleFan = 5;
  static const primSprite = 6;

  static const csrSignal = 1, csrFinish = 2, csrHsint = 4, csrVsint = 8;
  static const csrEdwint = 16;

  /// the TEX0 fields that TEX2 replaces: PSM and the CLUT fields
  static const _tex2Mask = 0xffffffe003f00000;

  final mem = GsMemory();
  late final GsRaster raster = GsRaster(this);

  /// raised when an unmasked event sets a CSR flag
  void Function()? onInterrupt;

  // privileged registers
  int pmode = 0, smode1 = 0, smode2 = 0, srfsh = 0;
  int synch1 = 0, synch2 = 0, syncv = 0;
  int dispfb1 = 0, display1 = 0, dispfb2 = 0, display2 = 0;
  int extbuf = 0, extdata = 0, extwrite = 0, bgcolor = 0;
  int csr = 0, imr = 0xff00, busdir = 0, siglblid = 0;
  int _field = 0;
  int _pendingInterrupts = 0;

  // general registers
  int prim = 0, prmode = 0, prmodecont = 1;
  int texclut = 0, scanmsk = 0, texa = 0, fogcol = 0;
  int dimx = 0, dthe = 0, colclamp = 1, pabe = 0, miptbp = 0;
  int bitbltbuf = 0, trxpos = 0, trxreg = 0, trxdir = 3;
  final contexts = [GsContext(), GsContext()];

  // vertex state
  int _r = 0, _g = 0, _b = 0, _a = 0;
  double _q = 1, _s = 0, _t = 0;
  int _u = 0, _v = 0, _fog = 0;
  final vertices = [GsVertex(), GsVertex(), GsVertex()];
  final _incoming = GsVertex();
  int _vertexCount = 0;

  // host <-> local transfer
  int _trxX = 0, _trxY = 0, _trxLeft = 0;
  int _acc = 0, _accBits = 0;

  void reset() {
    csr = 0;
    imr = 0xff00;
    _pendingInterrupts = 0;
    _vertexCount = 0;
    _trxLeft = 0;
    trxdir = 3;
  }

  // ---- privileged registers ----

  int readPrivileged(int address) {
    switch (address & 0x1fff) {
      case 0x0000:
        return pmode;
      case 0x0010:
        return smode1;
      case 0x0020:
        return smode2;
      case 0x0030:
        return srfsh;
      case 0x0040:
        return synch1;
      case 0x0050:
        return synch2;
      case 0x0060:
        return syncv;
      case 0x0070:
        return dispfb1;
      case 0x0080:
        return display1;
      case 0x0090:
        return dispfb2;
      case 0x00a0:
        return display2;
      case 0x00b0:
        return extbuf;
      case 0x00c0:
        return extdata;
      case 0x00d0:
        return extwrite;
      case 0x00e0:
        return bgcolor;
      case 0x1000:
        return csr | (_field << 13) | (0x55 << 24) | (0x1b << 16);
      case 0x1010:
        return imr;
      case 0x1040:
        return busdir;
      case 0x1080:
        return siglblid;
    }
    return 0;
  }

  void writePrivileged(int address, int value) {
    switch (address & 0x1fff) {
      case 0x0000:
        pmode = value;
      case 0x0010:
        smode1 = value;
      case 0x0020:
        smode2 = value;
      case 0x0030:
        srfsh = value;
      case 0x0040:
        synch1 = value;
      case 0x0050:
        synch2 = value;
      case 0x0060:
        syncv = value;
      case 0x0070:
        dispfb1 = value;
      case 0x0080:
        display1 = value;
      case 0x0090:
        dispfb2 = value;
      case 0x00a0:
        display2 = value;
      case 0x00b0:
        extbuf = value;
      case 0x00c0:
        extdata = value;
      case 0x00d0:
        extwrite = value;
      case 0x00e0:
        bgcolor = value;
      case 0x1000:
        if (value & 0x200 != 0) reset();
        csr &= ~(value & 0x1f);
        _pendingInterrupts &= ~(value & 0x1f);
      case 0x1010:
        imr = value;
        _signalInterrupt();
      case 0x1040:
        busdir = value;
      case 0x1080:
        siglblid = value;
    }
  }

  /// Sets a CSR event flag and raises the interrupt when it is not masked.
  void _event(int flag) {
    csr |= flag;
    _signalInterrupt();
  }

  void _signalInterrupt() {
    final active = csr & 0x1f & ~((imr >> 8) & 0x1f);
    if (active & ~_pendingInterrupts != 0) onInterrupt?.call();
    _pendingInterrupts = active;
  }

  /// called at the start of the vertical blank
  void vblank() {
    _field ^= 1;
    _event(csrVsint);
  }

  // ---- general registers ----

  GsContext _ctx(int n) => contexts[n];

  static double _float(int bits) {
    _convert.setUint32(0, bits & 0xffffffff);
    return _convert.getFloat32(0);
  }

  static final _convert = ByteData(4);

  /// the current Q as register bits, for the packed RGBAQ format
  int get qBits {
    _convert.setFloat32(0, _q);
    return _convert.getUint32(0);
  }

  void setQ(int bits) => _q = _float(bits);

  void writeRegister(int reg, int data) {
    switch (reg) {
      case 0x00:
        prim = data & 0x7ff;
        _vertexCount = 0;
      case 0x01:
        _r = data & 0xff;
        _g = (data >> 8) & 0xff;
        _b = (data >> 16) & 0xff;
        _a = (data >> 24) & 0xff;
        _q = _float(data >> 32);
      case 0x02:
        _s = _float(data);
        _t = _float(data >> 32);
      case 0x03:
        _u = data & 0x3fff;
        _v = (data >> 16) & 0x3fff;
      case 0x04:
        _vertex(data, true, true);
      case 0x05:
        _vertex(data, false, true);
      case 0x06 || 0x07:
        _ctx(reg - 0x06).tex0 = data;
        raster.loadClut(data);
      case 0x08:
        _ctx(0).clamp = data;
      case 0x09:
        _ctx(1).clamp = data;
      case 0x0a:
        _fog = (data >> 56) & 0xff;
      case 0x0c:
        _vertex(data, true, false);
      case 0x0d:
        _vertex(data, false, false);
      case 0x14:
        _ctx(0).tex1 = data;
      case 0x15:
        _ctx(1).tex1 = data;
      case 0x16 || 0x17:
        final c = _ctx(reg - 0x16);
        c.tex0 = (c.tex0 & ~_tex2Mask) | (data & _tex2Mask);
        raster.loadClut(c.tex0);
      case 0x18:
        _ctx(0).xyoffset = data;
      case 0x19:
        _ctx(1).xyoffset = data;
      case 0x1a:
        prmodecont = data & 1;
      case 0x1b:
        prmode = data & 0x7ff;
      case 0x1c:
        texclut = data;
      case 0x22:
        scanmsk = data;
      case 0x34 || 0x35:
        miptbp = data;
      case 0x3b:
        texa = data;
      case 0x3d:
        fogcol = data;
      case 0x3f:
        break;
      case 0x40:
        _ctx(0).scissor = data;
      case 0x41:
        _ctx(1).scissor = data;
      case 0x42:
        _ctx(0).alpha = data;
      case 0x43:
        _ctx(1).alpha = data;
      case 0x44:
        dimx = data;
      case 0x45:
        dthe = data & 1;
      case 0x46:
        colclamp = data & 1;
      case 0x47:
        _ctx(0).test = data;
      case 0x48:
        _ctx(1).test = data;
      case 0x49:
        pabe = data & 1;
      case 0x4a:
        _ctx(0).fba = data & 1;
      case 0x4b:
        _ctx(1).fba = data & 1;
      case 0x4c:
        _ctx(0).frame = data;
      case 0x4d:
        _ctx(1).frame = data;
      case 0x4e:
        _ctx(0).zbuf = data;
      case 0x4f:
        _ctx(1).zbuf = data;
      case 0x50:
        bitbltbuf = data;
      case 0x51:
        trxpos = data;
      case 0x52:
        trxreg = data;
      case 0x53:
        _startTransfer(data & 3);
      case 0x54:
        hostWord(data);
        hostWord(data >> 32);
      case 0x60:
        siglblid = (siglblid & ~(data >> 32 & 0xffffffff)) |
            (data & (data >> 32) & 0xffffffff);
        _event(csrSignal);
      case 0x61:
        _event(csrFinish);
      case 0x62: // LABEL: the masked bits of LBLID, in the upper half
        final mask = data >>> 32;
        final id = (siglblid >>> 32 & ~mask) | (data & mask);
        siglblid = (siglblid & 0xffffffff) | (id & 0xffffffff) << 32;
    }
  }

  void _vertex(int data, bool withFog, bool drawing) {
    _pushVertex(_incoming.copyFromState(this, data, withFog), drawing);
  }

  void _pushVertex(GsVertex incoming, bool drawing) {
    final type = prim & 7;
    if (type == primTriangleFan && _vertexCount >= 3) {
      // the first vertex of a fan stays; the newest replaces the second
      vertices[1].copyFrom(vertices[2]);
      vertices[2].copyFrom(incoming);
      _vertexCount = 3;
    } else {
      vertices[0].copyFrom(vertices[1]);
      vertices[1].copyFrom(vertices[2]);
      vertices[2].copyFrom(incoming);
      if (_vertexCount < 3) _vertexCount++;
    }
    if (!drawing) return;
    final attrs = prmodecont != 0 ? prim : prmode;
    switch (type) {
      case primPoint:
        raster.draw(this, type, attrs, vertices[2], vertices[2], vertices[2]);
        _vertexCount = 0;
      case primLine:
        if (_vertexCount >= 2) {
          raster.draw(this, type, attrs, vertices[1], vertices[2], vertices[2]);
          _vertexCount = 0;
        }
      case primLineStrip:
        if (_vertexCount >= 2) {
          raster.draw(
              this, primLine, attrs, vertices[1], vertices[2], vertices[2]);
        }
      case primTriangle:
        if (_vertexCount >= 3) {
          raster.draw(this, type, attrs, vertices[0], vertices[1], vertices[2]);
          _vertexCount = 0;
        }
      case primTriangleStrip:
        if (_vertexCount >= 3) {
          raster.draw(
              this, primTriangle, attrs, vertices[0], vertices[1], vertices[2]);
          _vertexCount = 2;
        }
      case primTriangleFan:
        if (_vertexCount >= 3) {
          raster.draw(
              this, primTriangle, attrs, vertices[0], vertices[1], vertices[2]);
        }
      case primSprite:
        if (_vertexCount >= 2) {
          raster.draw(this, type, attrs, vertices[1], vertices[2], vertices[2]);
          _vertexCount = 0;
        }
    }
  }

  // ---- transfers ----

  int get _dbp => (bitbltbuf >> 32) & 0x3fff;
  int get _dbw => (bitbltbuf >> 48) & 0x3f;
  int get _dpsm => (bitbltbuf >> 56) & 0x3f;
  int get _sbp => bitbltbuf & 0x3fff;
  int get _sbw => (bitbltbuf >> 16) & 0x3f;
  int get _spsm => (bitbltbuf >> 24) & 0x3f;

  int get _rrw => trxreg & 0xfff;
  int get _rrh => (trxreg >> 32) & 0xfff;

  void _startTransfer(int direction) {
    trxdir = direction;
    _trxX = 0;
    _trxY = 0;
    _acc = 0;
    _accBits = 0;
    final w = _rrw, h = _rrh;
    _trxLeft = w * h;
    if (direction == 2) {
      _localToLocal();
      _trxLeft = 0;
    } else if (direction == 3) {
      _trxLeft = 0;
    }
  }

  void _localToLocal() {
    final sx = trxpos & 0x7ff, sy = (trxpos >> 16) & 0x7ff;
    final dx = (trxpos >> 32) & 0x7ff, dy = (trxpos >> 48) & 0x7ff;
    final w = _rrw, h = _rrh;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final v =
            mem.read(_spsm, _sbp, _sbw, (sx + x) & 0x7ff, (sy + y) & 0x7ff);
        mem.write(_dpsm, _dbp, _dbw, (dx + x) & 0x7ff, (dy + y) & 0x7ff, v);
      }
    }
  }

  /// receives 32 bits of image data for a host to local transfer
  void hostWord(int word) {
    if (trxdir != 0 || _trxLeft <= 0) return;
    final psm = _dpsm;
    final bits = GsPsm.pixelBits(psm);
    _acc |= (word & 0xffffffff) << _accBits;
    _accBits += 32;
    final dx = (trxpos >> 32) & 0x7ff, dy = (trxpos >> 48) & 0x7ff;
    final w = _rrw;
    final mask = (1 << bits) - 1;
    while (_accBits >= bits && _trxLeft > 0) {
      mem.write(psm, _dbp, _dbw, (dx + _trxX) & 0x7ff, (dy + _trxY) & 0x7ff,
          _acc & mask);
      _acc >>>= bits;
      _accBits -= bits;
      _trxLeft--;
      if (++_trxX >= w) {
        _trxX = 0;
        _trxY++;
      }
    }
    if (_trxLeft == 0) {
      _acc = 0;
      _accBits = 0;
    }
  }

  void hostQuad(int low, int high) {
    hostWord(low);
    hostWord(low >>> 32);
    hostWord(high);
    hostWord(high >>> 32);
  }

  /// supplies 128 bits of a local to host transfer
  void readQuad(Int64List out) {
    out[0] = _readWords() | (_readWords() << 32);
    out[1] = _readWords() | (_readWords() << 32);
  }

  int _readWords() {
    if (trxdir != 1) return 0;
    final psm = _spsm;
    final bits = GsPsm.pixelBits(psm);
    final sx = trxpos & 0x7ff, sy = (trxpos >> 16) & 0x7ff;
    final w = _rrw;
    while (_accBits < 32 && _trxLeft > 0) {
      final v =
          mem.read(psm, _sbp, _sbw, (sx + _trxX) & 0x7ff, (sy + _trxY) & 0x7ff);
      _acc |= v << _accBits;
      _accBits += bits;
      _trxLeft--;
      if (++_trxX >= w) {
        _trxX = 0;
        _trxY++;
      }
    }
    final word = _acc & 0xffffffff;
    _acc >>>= 32;
    _accBits = _accBits > 32 ? _accBits - 32 : 0;
    return word;
  }

  // ---- output ----

  /// The picture the CRT would show: the read circuit that is enabled (2
  /// before 1) at the size of its display rectangle. Frame/field handling,
  /// merge circuits and the background colour are not applied.
  ImageBuffer image() {
    final useCircuit2 = pmode & 2 != 0;
    if (pmode & 3 == 0) return ImageBuffer.empty();
    final fb = useCircuit2 ? dispfb2 : dispfb1;
    final disp = useCircuit2 ? display2 : display1;
    final magh = (disp >> 23) & 15, magv = (disp >> 27) & 3;
    final width = (((disp >> 32) & 0xfff) + 1) ~/ (magh + 1);
    final height = (((disp >> 44) & 0x7ff) + 1) ~/ (magv + 1);
    if (width <= 0 || height <= 0 || width > 2048 || height > 2048) {
      return ImageBuffer.empty();
    }
    final psm = (fb >> 15) & 0x1f;
    final bp = (fb & 0x1ff) * 32, bw = (fb >> 9) & 0x3f;
    final dbx = (fb >> 32) & 0x7ff, dby = (fb >> 43) & 0x7ff;
    final out = Uint32List(width * height);
    if (!GsPsm.isValid(psm)) return ImageBuffer(width, height, out);
    // INT=1 with FFMD=1: both fields read the same lines, so the frame
    // buffer holds one field whose lines are shown twice in the full frame.
    // The BIOS uses this with 640x224 buffers (observed, unverified)
    final fieldMode = smode2 & 3 == 3;
    for (var y = 0; y < height; y++) {
      final sy = fieldMode ? y >> 1 : y;
      for (var x = 0; x < width; x++) {
        final raw = mem.read(psm, bp, bw, dbx + x, dby + sy);
        out[y * width + x] = _displayColor(psm, raw);
      }
    }
    return ImageBuffer(width, height, out);
  }

  static int _displayColor(int psm, int raw) {
    if (psm == GsPsm.ct16 || psm == GsPsm.ct16s) {
      final r = (raw & 31) << 3, g = ((raw >> 5) & 31) << 3;
      final b = ((raw >> 10) & 31) << 3;
      return 0xff000000 | (b << 16) | (g << 8) | r;
    }
    return 0xff000000 | (raw & 0xffffff);
  }
}

extension on GsVertex {
  /// fills the vertex from the current attribute state and a position write
  GsVertex copyFromState(Gs gs, int data, bool withFog) {
    x = data & 0xffff;
    y = (data >> 16) & 0xffff;
    if (withFog) {
      z = (data >> 32) & 0xffffff;
      f = (data >> 56) & 0xff;
    } else {
      z = (data >> 32) & 0xffffffff;
      f = gs._fog;
    }
    r = gs._r;
    g = gs._g;
    b = gs._b;
    a = gs._a;
    s = gs._s;
    t = gs._t;
    q = gs._q;
    u = gs._u;
    v = gs._v;
    return this;
  }
}
