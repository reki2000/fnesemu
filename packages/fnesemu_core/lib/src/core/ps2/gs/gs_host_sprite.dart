part of 'gs_raster.dart';

typedef GsDrawRecorder = void Function(
  Map<String, Object?> command,
  Ps2SpriteFrame? packet,
  Uint32List? before,
  Uint32List? after,
  Uint32List? depthBefore,
  Uint32List? depthAfter,
);

GsDrawRecorder? gsDrawRecorder;
void Function(GsHostDraw?, String)? gsReplayDraw;

/// Receives every primitive instead of the raster when set, with its Gs.prim*
/// type, the PRIM attribute bits in effect and its vertices (one for a point,
/// two for a line or a sprite, three for a triangle). The vertices are reused
/// for the next primitive. The registers of the primitive are those of the Gs
/// at the call.
void Function(int type, int attrs, List<GsVertex> vertices)? gsPrimitiveHook;

class _ResidentHazards {
  final written = Uint32List(GsMemory.size ~/ 4);
  final read = Uint32List(GsMemory.size ~/ 4);
  final _writeStamp = Uint32List(GsMemory.size ~/ 4);
  final _readStamp = Uint32List(GsMemory.size ~/ 4);
  int _generation = 0;

  void reset() => _generation++;
  int writesAt(int word) => _writeStamp[word] == _generation ? written[word] : 0;
  int readsAt(int word) => _readStamp[word] == _generation ? read[word] : 0;

  void markWrite(int word, int mask) {
    written[word] = writesAt(word) | mask;
    _writeStamp[word] = _generation;
  }

  void markRead(int word, int mask) {
    read[word] = readsAt(word) | mask;
    _readStamp[word] = _generation;
  }
}

_ResidentHazards? _residentHazards;

extension GsDrawRecording on GsRaster {
  void _recordDraw(int type, int attrs, List<GsVertex> vertices,
      _HostSprite? candidate, void Function() draw,
      {String unsupported = 'primitive'}) {
    final resident = gs.residentSink;
    if (resident != null) {
      resident.draw(candidate, unsupported);
      return;
    }
    final replay = gsReplayDraw;
    if (replay != null) {
      replay(candidate, unsupported);
      return;
    }
    final record = gsDrawRecorder!;
    final ctx = _ctx;
    final command = <String, Object?>{
      'primitive': type,
      'attributes': attrs,
      'vertices': [
        for (final v in vertices)
          [v.x, v.y, v.z, v.r, v.g, v.b, v.a, v.f, v.u, v.v,
           v.s.isFinite ? v.s : v.s.toString(),
           v.t.isFinite ? v.t : v.t.toString(),
           v.q.isFinite ? v.q : v.q.toString()],
      ],
      'registers': {
        'frame': ctx.frame.toUnsigned(64).toRadixString(16),
        'zbuf': ctx.zbuf.toUnsigned(64).toRadixString(16),
        'test': ctx.test.toUnsigned(64).toRadixString(16),
        'alpha': ctx.alpha.toUnsigned(64).toRadixString(16),
        'fba': ctx.fba,
        'xyoffset': ctx.xyoffset.toUnsigned(64).toRadixString(16),
        'scissor': ctx.scissor.toUnsigned(64).toRadixString(16),
        'tex0': ctx.tex0.toUnsigned(64).toRadixString(16),
        'tex1': ctx.tex1.toUnsigned(64).toRadixString(16),
        'clamp': ctx.clamp.toUnsigned(64).toRadixString(16),
        'miptbp1': ctx.miptbp1.toUnsigned(64).toRadixString(16),
        'miptbp2': ctx.miptbp2.toUnsigned(64).toRadixString(16),
        'texa': gs.texa.toUnsigned(64).toRadixString(16),
        'fogcol': gs.fogcol,
        'pabe': gs.pabe,
        'colclamp': gs.colclamp,
        'dthe': gs.dthe,
        'dimx': gs.dimx.toUnsigned(64).toRadixString(16),
      },
    };
    if (candidate == null) {
      command['unsupported'] = unsupported;
      draw();
      record(command, null, null, null, null, null);
      return;
    }
    command['bounds'] = [candidate.left, candidate.top, candidate.width, candidate.height];
    final rowEnds = candidate.orderedRowEnds;
    if (rowEnds != null && rowEnds.length > 1) command['rowEnds'] = rowEnds;
    command['colorMask'] = _fbmsk | (_fpsm == GsPsm.ct24 ? 0xff000000 : 0);
    command['forceAlpha'] = _fba != 0;
    command['colorFormat'] = _fcolor;
    final packet = candidate.buildFrame();
    final before = candidate.captureColor();
    final depthBefore = _zmsk ? null : candidate.captureDepth();
    draw();
    record(command, packet, before, candidate.captureColor(),
        depthBefore, _zmsk ? null : candidate.captureDepth());
  }
}

abstract class GsHostDraw {
  bool selectedForGpu = false;
  Uint8List? coverage;

  int get width;
  int get height;
  int get area;
  int get minimumArea => 4096;
  Ps2RenderFrame buildFrame();
  Uint32List buildResidentState() => throw UnsupportedError('resident GS draw');
  List<int>? get residentRowEnds => null;
  void drawSoftware(GsMemory mem);
  void writeCoverage(GsMemory mem, Uint8List pixels);
}

extension GsHostSprites on GsRaster {
  GsHostDraw? drawTriangle(int attrs, GsVertex a, GsVertex b, GsVertex c,
      {required bool allowHost}) {
    final hook = gsPrimitiveHook;
    if (hook != null) {
      hook(Gs.primTriangle, attrs, [a, b, c]);
      return null;
    }
    _setup(attrs >> 9 & 1, attrs);
    final recording =
        gs.residentSink != null || gsDrawRecorder != null || gsReplayDraw != null;
    final eligible = (!_fge || recording) &&
        (!_tme || !_mipmap || recording && _wms <= 2 && _wmt <= 2) &&
        _hostFormats && attrs & 0x80 == 0 &&
        (!_tme || _boundedTexture) &&
        (_zmsk || recording && _zmax <= 0xffffff);
    final candidate = (allowHost || recording) && eligible
        ? _HostSprite.tryTriangle(this, a, b, c, recording: recording)
        : null;
    if (recording) {
      final empty = _HostSprite._emptyTriangle(this, a, b, c);
      _recordDraw(Gs.primTriangle, attrs, [a, b, c], empty ? null : candidate,
          () => _triangle(a, b, c),
          unsupported: empty ? 'no_raster_effect' : eligible
              ? 'bounds_or_memory_alias'
              : _tme && _mipmap ? 'mipmap' : 'triangle_state');
      return null;
    }
    if (candidate != null) return candidate;
    _triangle(a, b, c);
    return null;
  }

  bool get _hostFormats =>
      (_fcolor == GsPsm.ct32 || _fcolor == GsPsm.ct24 ||
       _fcolor == GsPsm.ct16 || _fcolor == GsPsm.ct16s) &&
      GsPsm.isValid(_fpsm) && GsPsm.isValid(_zpsm);

  bool get _boundedTexture {
    bool bounded(int mode, int min, int max, int size) => switch (mode) {
      2 => min < size && max < size,
      3 => (min | max) < size,
      _ => true,
    };
    return GsPsm.isValid(_tpsm) &&
        bounded(_wms, _minu, _maxu, 1 << _tw) &&
        bounded(_wmt, _minv, _maxv, 1 << _th);
  }

  GsHostDraw? drawSprite(int attrs, GsVertex a, GsVertex b,
      {required bool allowHost}) {
    final hook = gsPrimitiveHook;
    if (hook != null) {
      hook(Gs.primSprite, attrs, [a, b]);
      return null;
    }
    _setup(attrs >> 9 & 1, attrs);
    final recording =
        gs.residentSink != null || gsDrawRecorder != null || gsReplayDraw != null;
    _HostSprite? candidate;
    if ((allowHost || recording) && _hostFormats && attrs & 0x80 == 0 &&
        (!_fge || recording) &&
        (!_tme || _fst && !_mipmap &&
            (_boundedTexture || recording && !_linear && _tpsm == GsPsm.t8))) {
      candidate = _HostSprite.tryCreate(this, a, b, recording: recording);
    }
    if (recording) {
      _recordDraw(Gs.primSprite, attrs, [a, b], candidate, () => _sprite(a, b),
          unsupported: !_tme ? 'untextured_sprite' : 'sprite_state_or_bounds');
      return null;
    }
    if (candidate != null) return candidate;
    _sprite(a, b);
    return null;
  }
}

/// A deferred sprite keeps the raster's decoded state until the next
/// local memory access. Raster setup resolves the pending draw first.
class _HostSprite extends GsHostDraw {
  _HostSprite(this.raster, this.a, this.b, this.left, this.top, this.width,
      this.height, this.x0, this.y0, this.dx, this.dy, [this.c]);

  final GsRaster raster;
  final GsVertex a, b;
  final GsVertex? c;
  List<int>? orderedRowEnds;
  int _snapshotStart = 0, _snapshotEnd = 0;
  bool get _snapshot => _snapshotEnd > _snapshotStart;
  bool _disjointSurfaces = false;
  @override
  List<int>? get residentRowEnds => orderedRowEnds;
  @override
  int get minimumArea => c == null ? 4096 : 64;
  final int left, top, x0, y0, dx, dy;
  @override
  final int width, height;

  @override
  int get area => width * height;

  static _HostSprite? tryCreate(GsRaster r, GsVertex a, GsVertex b,
      {required bool recording}) {
    final x0 = math.min(a.x, b.x) - r._ofx;
    final y0 = math.min(a.y, b.y) - r._ofy;
    final x1 = math.max(a.x, b.x) - r._ofx;
    final y1 = math.max(a.y, b.y) - r._ofy;
    final left = math.max((x0 + 15) >> 4, r._sx0);
    final top = math.max((y0 + 15) >> 4, r._sy0);
    final right = math.min((x1 + 15) >> 4, r._sx1 + 1);
    final bottom = math.min((y1 + 15) >> 4, r._sy1 + 1);
    if (left >= right || top >= bottom || x0 == x1 || y0 == y1) return null;
    final width = right - left, height = bottom - top;
    if ((!recording && width * height < 4096) || height > 1024 || width > 1024) return null;

    final sprite = _HostSprite(r, GsVertex()..copyFrom(a), GsVertex()..copyFrom(b),
        left, top, width, height, x0, y0, x1 - x0, y1 - y0);
    final coordinatesBounded = !r._tme || r._boundedTexture;
    if (coordinatesBounded && _independent(r, left, top, right, bottom)) {
      sprite._disjointSurfaces = true;
      return sprite;
    }
    if (recording && sprite._safeTextureSnapshot()) {
      return sprite;
    }
    return null;
  }

  static bool _emptyTriangle(GsRaster r, GsVertex a, GsVertex b, GsVertex c) {
    final area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
    return area == 0 ||
        (math.min(a.x, math.min(b.x, c.x)) - r._ofx) >> 4 > r._sx1 ||
        (math.min(a.y, math.min(b.y, c.y)) - r._ofy) >> 4 > r._sy1 ||
        (math.max(a.x, math.max(b.x, c.x)) - r._ofx + 15) >> 4 < r._sx0 ||
        (math.max(a.y, math.max(b.y, c.y)) - r._ofy + 15) >> 4 < r._sy0;
  }

  static _HostSprite? tryTriangle(GsRaster r, GsVertex a, GsVertex b, GsVertex c,
      {required bool recording}) {
    final minX = math.min(a.x, math.min(b.x, c.x)) - r._ofx;
    final minY = math.min(a.y, math.min(b.y, c.y)) - r._ofy;
    final maxX = math.max(a.x, math.max(b.x, c.x)) - r._ofx;
    final maxY = math.max(a.y, math.max(b.y, c.y)) - r._ofy;
    final left = math.max(minX >> 4, r._sx0);
    final top = math.max(minY >> 4, r._sy0);
    final right = math.min(((maxX + 15) >> 4) + 1, r._sx1 + 1);
    final bottom = math.min(((maxY + 15) >> 4) + 1, r._sy1 + 1);
    final width = right - left, height = bottom - top;
    if (left >= right || top >= bottom ||
        !recording && (width * height < 64 || maxX - minX > 8192 || maxY - minY > 8192)) {
      return null;
    }
    final triangle = _HostSprite(r, GsVertex()..copyFrom(a), GsVertex()..copyFrom(b),
        left, top, width, height, 0, 0, 1, 1, GsVertex()..copyFrom(c));
    if (_independent(r, left, top, right, bottom)) {
      triangle._disjointSurfaces = true;
      return triangle;
    }
    if (!recording) return null;
    if (triangle._safeTextureSnapshot()) return triangle;
    triangle.orderedRowEnds = triangle._feedbackPasses();
    if (triangle.orderedRowEnds == null) return null;
    final frame = _blocks(
        r._frameLayout, r._fbp, r._framePages, left, top, right, bottom)!;
    triangle._snapshotStart = frame.$1 * 64;
    triangle._snapshotEnd = frame.$2 * 64;
    return triangle;
  }

  static bool _independent(GsRaster r, int left, int top, int right, int bottom) {
    final frame = _blocks(
        r._frameLayout, r._fbp, r._framePages, left, top, right, bottom);
    final tex = r._tme ? _blocks(
        r._texLayout, r._tbp, r._texPages, 0, 0, 1 << r._tw, 1 << r._th) : (0, 0);
    if (frame == null || tex == null || (r._tme && _overlap(frame, tex))) return false;
    final sources = [tex];
    if (r._tme && r._mipmap && r._mmin >= 2) {
      for (var n = 1; n <= r._mxl; n++) {
        final level = _blocks(r._texLayout, r._mipTbp[n], r._mipPages[n],
            0, 0, 1 << r._mipTw[n], 1 << r._mipTh[n]);
        if (level == null || _overlap(frame, level)) return false;
        sources.add(level);
      }
    }
    if (!r._zmsk || r._zte && r._ztst >= 2) {
      final depth =
          _blocks(r._zLayout, r._zbp, r._zPages, left, top, right, bottom);
      if (depth == null ||
          _overlap(frame, depth) ||
          !r._zmsk && r._tme && sources.any((source) => _overlap(source, depth))) {
        return false;
      }
    }
    return true;
  }

  static (int, int)? _blocks(GsLayout layout, int base, int pages, int left,
      int top, int right, int bottom) {
    final lastX = (right - 1) >> layout.xBits;
    if (lastX >= pages) return null;
    final first = (top >> layout.yBits) * pages + (left >> layout.xBits);
    final last = ((bottom - 1) >> layout.yBits) * pages + lastX;
    final end = base + (last + 1) * 32;
    if (end > GsMemory.size ~/ 256) return null;
    return (base + first * 32, end);
  }

  static bool _overlap((int, int) a, (int, int) b) =>
      a.$1 < b.$2 && b.$1 < a.$2;

  @override
  void drawSoftware(GsMemory mem) {
    final last = c;
    if (last == null) {
      raster._sprite(a, b);
    } else {
      raster._triangle(a, b, last);
    }
  }

  List<int> _axis(bool x) {
    final r = raster;
    final n = x ? width : height;
    final start = x ? a.u : a.v, end = x ? b.u : b.v;
    final offset = x ? left : top, origin = x ? x0 : y0;
    final length = x ? dx : dy;
    final mode = x ? r._wms : r._wmt;
    final size = 1 << (x ? r._tw : r._th);
    final min = x ? r._minu : r._minv, max = x ? r._maxu : r._maxv;
    return [
      for (var i = 0; i < n; i++)
        GsRaster._wrap(((start + (end - start) *
            (((offset + i) * 16 - origin) / length)) / 16).floor(),
            mode, size, min, max),
    ];
  }

  // Give every GS storage unit a 32-bit word address and a mask within it.
  static (int, int) _wordBits(int psm, GsLayout layout, int index, int mask) {
    final unit = index & ((GsMemory.size << layout.unitShift) ~/ 4 - 1);
    final shift = switch (psm) {
      GsPsm.t8h || GsPsm.t4hl => 24,
      GsPsm.t4hh => 28,
      _ => (unit & ((1 << layout.unitShift) - 1)) * (32 >> layout.unitShift),
    };
    return (unit >> layout.unitShift, mask << shift);
  }

  static int _pixelMask(int psm) => (1 << GsPsm.pixelBits(psm)) - 1;

  bool _safeTextureSnapshot() {
    final r = raster;
    if (r._tme && r._mipmap) return false;
    final colorBits = _pixelMask(r._fpsm);
    final colorWrites = colorBits & ~r._fbmsk;
    final depthBits = _pixelMask(r._zpsm);
    final depthWrites = !r._zmsk;
    final depthReads = r._zte && r._ztst >= 2;
    final textureBits = r._tme ? _pixelMask(r._tpsm) : 0;
    final hazards = r.gs.residentSink == null
        ? null
        : (_residentHazards ??= _ResidentHazards());
    hazards?.reset();
    final written = hazards == null ? <int, int>{} : null;
    final triangle = c != null;
    var firstSnapshot = GsMemory.size ~/ 4, endSnapshot = 0;
    final linearSprite = !triangle && r._tme && r._linear;

    (int, int) color(int x, int y) => _wordBits(r._fpsm, r._frameLayout,
        r._frameLayout.index(r._fbp, r._framePages, left + x, top + y), colorBits);
    (int, int) depth(int x, int y) => _wordBits(r._zpsm, r._zLayout,
        r._zLayout.index(r._zbp, r._zPages, left + x, top + y), depthBits);
    bool overlaps((int, int) address) =>
        ((hazards?.writesAt(address.$1) ?? written![address.$1] ?? 0) & address.$2) != 0;
    void mark((int, int) address) {
      final (word, bits) = address;
      if (hazards == null) {
        written!.update(word, (mask) => mask | bits, ifAbsent: () => bits);
      } else {
        hazards.markWrite(word, bits);
        // Include every possible write for linear sampling. A GPU rounding
        // difference can move a tap into a neighboring texel.
        if (linearSprite || (hazards.readsAt(word) & bits) != 0) {
          firstSnapshot = math.min(firstSnapshot, word);
          endSnapshot = math.max(endSnapshot, word + 1);
        }
      }
    }
    bool textureOverlaps(int u, int v) {
      final address = _wordBits(r._tpsm, r._texLayout,
          r._texLayout.index(r._tbp, r._texPages, u, v), textureBits);
      if (!triangle && !linearSprite) hazards?.markRead(address.$1, address.$2);
      return overlaps(address);
    }

    final columns = r._tme && !triangle ? _textureTaps(true) : const <(int, int)>[];
    final rows = r._tme && !triangle ? _textureTaps(false) : const <(int, int)>[];
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final f = color(x, y);
        final z = depthReads || depthWrites ? depth(x, y) : (0, 0);
        if (overlaps(f) || overlaps(z)) return false;
        if (depthWrites && f.$1 == z.$1 && f.$2 & z.$2 != 0) return false;
        if (r._tme && !triangle) {
          final (u0, u1) = columns[x];
          final (v0, v1) = rows[y];
          if (textureOverlaps(u0, v0) || r._linear &&
              (textureOverlaps(u1, v0) || textureOverlaps(u0, v1) ||
               textureOverlaps(u1, v1))) {
            return false;
          }
        }
        if (colorWrites != 0) {
          final fi = r._frameLayout.index(r._fbp, r._framePages, left + x, top + y);
          mark(_wordBits(r._fpsm, r._frameLayout, fi, colorWrites));
        }
        if (depthWrites) mark(z);
      }
    }
    if (!triangle) {
      if (endSnapshot > firstSnapshot) {
        _snapshotStart = firstSnapshot;
        _snapshotEnd = endSnapshot;
      }
      return true;
    }
    if (!r._tme) return true;

    // A texture rectangle can share VRAM pages with the destination. Only
    // compare the texels reachable by the primitive's interpolation.
    final us = _triangleTextureAxis(true);
    final vs = _triangleTextureAxis(false);
    for (final v in vs) {
      for (final u in us) {
        if (textureOverlaps(u, v)) return false;
      }
    }
    return true;
  }

  (int, int) _wrapTextureTaps(bool x, int first, int last) {
    final r = raster;
    final mode = x ? r._wms : r._wmt;
    final size = 1 << (x ? r._tw : r._th);
    final min = x ? r._minu : r._minv, max = x ? r._maxu : r._maxv;
    return (GsRaster._wrap(first, mode, size, min, max),
        GsRaster._wrap(last, mode, size, min, max));
  }

  List<(int, int)> _textureTaps(bool x) {
    if (!raster._linear) return [for (final i in _axis(x)) (i, i)];
    final start = x ? a.u : a.v, end = x ? b.u : b.v;
    final offset = x ? left : top, origin = x ? x0 : y0;
    final length = x ? dx : dy;
    return List.generate(x ? width : height, (i) {
      final coordinate = (start + (end - start) *
          (((offset + i) * 16 - origin) / length)) / 16 - 0.5;
      return _wrapTextureTaps(x, coordinate.floor(), coordinate.floor() + 1);
    });
  }

  Set<int> _triangleTextureAxis(bool x) {
    final r = raster, last = c!;
    final size = 1 << (x ? r._tw : r._th);
    final sameSignQ = [a, b, last].every((v) => v.q.isFinite && v.q > 0) ||
        [a, b, last].every((v) => v.q.isFinite && v.q < 0);
    if (!r._fst && !sameSignQ) return {for (var i = 0; i < size; i++) i};
    final coordinates = [
      for (final v in [a, b, last])
        r._fst ? (x ? v.u : v.v) / 16 : (x ? v.s : v.t) / v.q * size,
    ];
    if (coordinates.any((uv) => !uv.isFinite)) {
      return {for (var i = 0; i < size; i++) i};
    }
    final first = GsRaster._finite(coordinates.reduce(math.min)).floor() - 1;
    final end = GsRaster._finite(coordinates.reduce(math.max)).floor() + 1;
    return {for (var i = first; i <= end; i++) _wrapTextureTaps(x, i, i).$1};
  }

  // Identical 32-bit layouts let the checker feed GPU color writes back
  // into the texture using the same coordinates. Split before any scanline
  // that reads a texture pixel written earlier in the current pass.
  List<int>? _feedbackPasses() {
    final r = raster;
    if (c == null || !r._tme || !r._fst || r._mipmap || !r._boundedTexture ||
        !r._zmsk || r._fpsm != GsPsm.ct32 || r._tpsm != GsPsm.ct32 ||
        r._fbp != r._tbp || r._framePages != r._texPages) {
      return null;
    }
    final tw = 1 << r._tw, th = 1 << r._th;
    if (_blocks(r._texLayout, r._tbp, r._texPages, 0, 0, tw, th) == null ||
        _blocks(r._frameLayout, r._fbp, r._framePages,
            left, top, left + width, top + height) == null) {
      return null;
    }

    // A depth test sharing VRAM would also need to see the feedback.
    if (r._zte && r._ztst >= 2) {
      final depth = _blocks(r._zLayout, r._zbp, r._zPages, left, top,
          left + width, top + height);
      final frame = _blocks(r._frameLayout, r._fbp, r._framePages, left,
          top, left + width, top + height)!;
      if (depth == null || _overlap(frame, depth)) return null;
    }

    int edge(GsVertex a, GsVertex b, int x, int y) =>
        (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x);
    bool covered(int e, GsVertex a, GsVertex b) =>
        e > 0 || e == 0 && GsRaster._topLeft(b.x - a.x, b.y - a.y);
    final va = a;
    var vb = b, vc = c!;
    var area = edge(va, vb, vc.x, vc.y);
    if (area == 0) return [height];
    if (area < 0) {
      (vb, vc) = (vc, vb);
      area = -area;
    }
    final inv = 1.0 / area;
    final passWrites = <int>{}, rowWrites = <int>{};
    final ends = <int>[];
    for (var y = 0; y < height; y++) {
      rowWrites.clear();
      var needsPreviousPass = false;
      final py = (top + y) * 16 + r._ofy;
      for (var x = 0; x < width; x++) {
        final px = (left + x) * 16 + r._ofx;
        final ea = edge(vb, vc, px, py), eb = edge(vc, va, px, py);
        final ec = edge(va, vb, px, py);
        if (!covered(ea, vb, vc) || !covered(eb, vc, va) ||
            !covered(ec, va, vb)) {
          continue;
        }
        final wa = ea * inv, wb = eb * inv, wc = ec * inv;
        final center = r._linear ? 0.5 : 0.0;
        final u = (va.u * wa + vb.u * wb + vc.u * wc) / 16 - center;
        final v = (va.v * wa + vb.v * wb + vc.v * wc) / 16 - center;
        // Include adjacent taps at a possible GPU rounding boundary.
        const margin = 1 / 1024;
        final tail = r._linear ? 1 : 0;
        final (u0, u1) = ((u - margin).floor(), (u + margin).floor() + tail);
        final (v0, v1) = ((v - margin).floor(), (v + margin).floor() + tail);
        for (var j = v0; j <= v1; j++) {
          final tv = _wrapTextureTaps(false, j, j).$1;
          for (var i = u0; i <= u1; i++) {
            final tu = _wrapTextureTaps(true, i, i).$1;
            final address = tv * tw + tu;
            if (rowWrites.contains(address)) return null;
            needsPreviousPass |= passWrites.contains(address);
          }
        }
        if (left + x < tw && top + y < th) {
          rowWrites.add((top + y) * tw + left + x);
        }
      }
      if (needsPreviousPass) {
        ends.add(y);
        passWrites.clear();
      }
      passWrites.addAll(rowWrites);
    }
    return [...ends, height];
  }

  @override
  Ps2SpriteFrame buildFrame() {
    final r = raster, mem = raster._mem;
    final nearestSprite = c == null && r._tme && !r._linear;
    final xs = nearestSprite ? _axis(true) : const <int>[];
    final ys = nearestSprite ? _axis(false) : const <int>[];
    final uniqueX = xs.toSet().toList(), uniqueY = ys.toSet().toList();
    final tw = !r._tme ? 1 : nearestSprite ? uniqueX.length : 1 << r._tw;
    final th = !r._tme ? 1 : nearestSprite ? uniqueY.length : 1 << r._th;
    final inputWidth = math.max(tw, math.max(width, height));
    final levels = r._tme && r._mipmap && r._mmin >= 2 ? r._mxl : 0;
    var textureRows = th;
    for (var n = 1; n <= levels; n++) {
      textureRows += 1 << r._mipTh[n];
    }
    final inputHeight = textureRows + height * 2 + 2;
    final input = Uint8List(inputWidth * inputHeight * 4);
    final words = ByteData.sublistView(input);
    void put(int x, int y, int value) =>
        words.setUint32((y * inputWidth + x) * 4, value, Endian.little);

    if (r._tme) {
      for (var y = 0; y < th; y++) {
        for (var x = 0; x < tw; x++) {
          put(x, y, r._texel(nearestSprite ? uniqueX[x] : x, nearestSprite ? uniqueY[y] : y));
        }
      }
    }
    final base = r._tbp, pages = r._texPages;
    var textureY = th;
    for (var n = 1; n <= levels; n++) {
      r._tbp = r._mipTbp[n];
      r._texPages = r._mipPages[n];
      final w = 1 << r._mipTw[n], h = 1 << r._mipTh[n];
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          put(x, textureY + y, r._texel(x, y));
        }
      }
      textureY += h;
    }
    r._tbp = base;
    r._texPages = pages;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (r._abe || r._date) {
          final fi = r._frameLayout.index(r._fbp, r._framePages, left + x, top + y);
          final dst = mem.readAt(r._fpsm, fi);
          r._decodeFrame(dst);
          put(x, textureRows + y, r._dr | r._dg << 8 | r._db << 16 | r._da << 24);
        }
        if (r._zte && r._ztst >= 2) {
          final zi = r._zLayout.index(r._zbp, r._zPages, left + x, top + y);
          put(x, textureRows + height + y, mem.readAt(r._zpsm, zi));
        }
      }
    }
    if (nearestSprite) {
      final mapRow = inputHeight - 2;
      final xIndex = {for (final (i, x) in uniqueX.indexed) x: i};
      final yIndex = {for (final (i, y) in uniqueY.indexed) y: i};
      for (var x = 0; x < width; x++) {
        put(x, mapRow, xIndex[xs[x]]!);
      }
      for (var y = 0; y < height; y++) {
        put(y, mapRow + 1, yIndex[ys[y]]!);
      }
    }
    final planes = c != null && !r._zmsk ? 3 : 2;
    return Ps2SpriteFrame(width, height, inputWidth, inputHeight, input,
        _shaderState(inputWidth, inputHeight, textureRows, levels, planes),
        planes: planes);
  }

  Float32List _shaderState(
      int inputWidth, int inputHeight, int textureRows, int levels, int planes) {
    final r = raster;
    final shortFrame = r._fcolor == GsPsm.ct16 || r._fcolor == GsPsm.ct16s;
    final z = b.z.clamp(0, r._zmax), last = c;
    return Float32List.fromList([
          width.toDouble(), height.toDouble(), inputWidth.toDouble(), inputHeight.toDouble(),
          textureRows.toDouble(), (r._zte ? r._ztst : 1).toDouble(), (z & 0xffff).toDouble(), (z >> 16).toDouble(),
          b.r.toDouble(), b.g.toDouble(), b.b.toDouble(), b.a.toDouble(),
          r._tme ? r._tfx.toDouble() : -1, r._tcc.toDouble(), r._abe ? 1 : 0, r._pabe ? 1 : 0,
          r._blendA.toDouble(), r._blendB.toDouble(), r._blendC.toDouble(), r._blendD.toDouble(),
          r._fix.toDouble(), r._colclamp ? 1 : 0, (r._ate ? r._atst : 1).toDouble(), r._aref.toDouble(),
          r._afail.toDouble(), r._date && r._fcolor != GsPsm.ct24 ? (r._datm ? 2 : 1) : 0,
          r._zmsk ? 0 : 1, last == null ? 0 : 1,
          (r._tme ? 1 << r._tw : 1).toDouble(), (r._tme ? 1 << r._th : 1).toDouble(),
          (r._wms | r._wmt << 2).toDouble(), r._linear ? 1 : 0,
          r._fst ? 1 : 0, r._iip ? 1 : 0, r._zmax.toDouble(), planes.toDouble(),
          for (final v in [a, b, last ?? b]) ...[
            (v.x - r._ofx - left * 16).toDouble(),
            (v.y - r._ofy - top * 16).toDouble(), v.z.toDouble(), v.q,
            r._fst ? v.u / 16 : v.s, r._fst ? v.v / 16 : v.t, v.f.toDouble(), 0,
            v.r.toDouble(), v.g.toDouble(), v.b.toDouble(), v.a.toDouble(),
          ],
          r._minu.toDouble(), r._minv.toDouble(),
          r._maxu.toDouble(), r._maxv.toDouble(),
          (r.gs.fogcol & 255).toDouble(), (r.gs.fogcol >> 8 & 255).toDouble(),
          (r.gs.fogcol >> 16 & 255).toDouble(), r._fge ? 1 : 0,
          dx.toDouble(), dy.toDouble(), (left * 16 - x0).toDouble(), (top * 16 - y0).toDouble(),
          (left & 3).toDouble(), (top & 3).toDouble(), shortFrame && r.gs.dthe != 0 ? 1 : 0, 0,
          for (var i = 0; i < 16; i++)
            ((r.gs.dimx >> (i * 4)) & 7).toSigned(3).toDouble(),
          r._tme && r._mipmap ? 1 : 0, r._lcm ? 0 : (1 << r._l).toDouble(),
          r._k, levels.toDouble(),
          r._mmin.toDouble(), 0, 0, 0,
        ]);
  }

  @override
  Uint32List buildResidentState() {
    final r = raster;
    final levels = r._tme && r._mipmap && r._mmin >= 2 ? r._mxl : 0;
    final state = _shaderState(0, 0, 0, levels, c != null && !r._zmsk ? 3 : 2);
    final words = Uint32List(160);
    words.setAll(0, Uint32List.view(state.buffer));
    words.setAll(112, [
      left, top, width, height,
      r._fpsm, r._fbp, r._framePages, r._fbmsk, r._fba,
      r._zpsm, r._zbp, r._zPages,
      r._tpsm, r._tbp, r._texPages, r._clutPsm, r._clutOffset,
      r._ta0, r._ta1, r._aem ? 1 : 0,
      if (_snapshot) 1 else 0,
      for (var n = 1; n <= 6; n++) ...[r._mipTbp[n], r._mipPages[n]],
    ]);
    words[149] = _snapshotStart;
    words[150] = _snapshotEnd;
    words[151] = _disjointSurfaces ? 1 : 0;
    return words;
  }

  Uint32List captureColor() {
    final r = raster;
    final out = Uint32List(area);
    var i = 0;
    for (var y = top; y < top + height; y++) {
      for (var x = left; x < left + width; x++) {
        out[i++] = r._mem.readAt(r._fpsm, r._frameLayout.index(r._fbp, r._framePages, x, y));
      }
    }
    return out;
  }

  Uint32List captureDepth() {
    final r = raster;
    final out = Uint32List(area);
    var i = 0;
    for (var y = top; y < top + height; y++) {
      for (var x = left; x < left + width; x++) {
        out[i++] = r._mem.readAt(r._zpsm,
            r._zLayout.index(r._zbp, r._zPages, x, y));
      }
    }
    return out;
  }

  @override
  void writeCoverage(GsMemory mem, Uint8List pixels) {
    final r = raster;
    final planes = c != null && !r._zmsk ? 3 : 2;
    if (pixels.length != area * planes * 4) return;
    final constantZ = b.z.clamp(0, r._zmax);
    for (var y = 0; y < height; y++) {
      var rgb = y * width * planes * 4;
      var flags = rgb + width * 4;
      var depth = flags + width * 4;
      for (var x = 0; x < width; x++, rgb += 4, flags += 4, depth += 4) {
        if (pixels[flags + 2] == 1) {
          final zi = r._zLayout.index(r._zbp, r._zPages, left + x, top + y);
          final z = planes == 2 ? constantZ :
              pixels[depth] | pixels[depth + 1] << 8 | pixels[depth + 2] << 16;
          mem.writeAt(r._zpsm, zi, z);
        }
        final color = pixels[flags + 1];
        if (color == 0) continue;
        final fi = r._frameLayout.index(r._fbp, r._framePages, left + x, top + y);
        r._writeFrame(fi, mem.readAt(r._fpsm, fi), pixels[rgb],
            pixels[rgb + 1], pixels[rgb + 2], pixels[flags], color == 2);
      }
    }
  }
}
