// The compute GS: takes the primitives, transfers and CLUT loads of a Gs,
// and turns them into ordered steps of the program in gs_compute_shader.dart
// on the GPU of a ComputeSink, where the local memory stays resident.
//
// Ordering: the steps run in order on the GPU. Draws with the same frame and
// depth buffers go into one raster batch, in which every pixel is owned by
// one thread. A batch closes when a draw reads a page the batch writes as a
// texture, writes a page an earlier draw of the batch reads, or uses other
// buffers. CLUT loads become versions of the CLUT that the draws refer to,
// read by one step per group of versions; a group runs before the open batch
// unless a load reads a page the batch writes. Transfers run before the open
// batch and group unless they touch their pages. A draw that reads its own
// target pages reads them from a snapshot taken before the batch.
import 'dart:typed_data';

import '../../../compute_sink.dart';
import 'gs.dart';
import 'gs_compute_shader.dart';
import 'gs_memory.dart';

const primWords = 28;
const stateWords = 80;
const _maxPrims = 262144;
const _maxSteps = 65536;
const _dataWords = 16 * 1024 * 1024;
const _versions = 2048;

// step kinds: the indices of the entry points in [_entryPoints]
const _setup = 0, _raster = 1, _clut = 2, _upload = 3, _copy = 4, _snapshot = 5;
const _entryPoints = ['setup', 'raster', 'clut', 'upload', 'copy', 'snapshot'];

// the bindings of the program
const _vramBinding = 0, _primBinding = 2, _dataBinding = 4, _clutBinding = 5;
const _bindings = [
  ComputeBinding(ComputeBindingKind.storage, GsMemory.size), // vram
  ComputeBinding(ComputeBindingKind.storage, GsMemory.size), // snapshot
  ComputeBinding(ComputeBindingKind.readOnlyStorage, _maxPrims * primWords * 4),
  ComputeBinding(ComputeBindingKind.storage, _maxPrims * 12 * 4), // setups
  ComputeBinding(ComputeBindingKind.readOnlyStorage, _dataWords * 4),
  ComputeBinding(ComputeBindingKind.storage, _versions * 512 * 4), // CLUTs
  ComputeBinding(ComputeBindingKind.params, 64),
];

/// 512 pages of 8 KiB as a bit set
class _Pages {
  final bits = Uint32List(16);
  bool any = false;

  void clear() {
    if (!any) return;
    bits.fillRange(0, 16, 0);
    any = false;
  }

  void add(int page) {
    page &= 511;
    bits[page >> 5] |= 1 << (page & 31);
    any = true;
  }

  void addAll(_Pages o) {
    if (!o.any) return;
    for (var i = 0; i < 16; i++) {
      bits[i] |= o.bits[i];
    }
    any = true;
  }

  bool has(int page) => bits[page >> 5] & (1 << (page & 31)) != 0;

  bool meets(_Pages o) {
    if (!any || !o.any) return false;
    for (var i = 0; i < 16; i++) {
      if (bits[i] & o.bits[i] != 0) return true;
    }
    return false;
  }

  Iterable<int> get pages sync* {
    for (var p = 0; p < 512; p++) {
      if (bits[p >> 5] & (1 << (p & 31)) != 0) yield p;
    }
  }
}

/// Runs the GS on a [ComputeSink]. While attached, it takes the work of
/// the Gs, and copies the local memory and the CLUT back into the Gs at each
/// vblank and before a local to host transfer, so that the Gs makes its
/// pictures, transfers and states from them as without it.
class GsCompute implements GsResidentSink {
  /// Compiles the program on [sink]; throws if it cannot.
  GsCompute(this.gs, ComputeSink sink)
      : _program = sink.program(gsComputeShader, _entryPoints, _bindings,
            paramStride: 256, maxDispatches: _maxSteps);

  final Gs gs;
  final ComputeProgram _program;

  /// counts of the work that is not done as on the hardware, for tools
  final unsupported = <String, int>{};
  final stepCounts = <String, int>{};
  int draws = 0, submits = 0;

  /// the milliseconds spent in runs, including the waits
  double gpuMs = 0;

  final _prims = Uint32List(_maxPrims * primWords);
  late final _primFloats = Float32List.view(_prims.buffer);
  final _data = Uint32List(_dataWords);
  late final _dataFloats = Float32List.view(_data.buffer);
  final _steps = Uint32List(_maxSteps * 4);
  final _params = Uint32List(_maxSteps * 64);
  int _primCount = 0, _dataLength = 0, _stepCount = 0;

  /// the steps after which a run is submitted without waiting, so that the
  /// GPU works while the core issues the rest; 0 submits once at each sync
  int chunkSteps = 64;

  void _count(Map<String, int> m, String key) => m[key] = (m[key] ?? 0) + 1;

  /// Copies the local memory and the CLUT of the Gs to the GPU and takes the
  /// work of the Gs.
  void attach() {
    _program.write(_vramBinding, 0, gs.mem.words);
    _version = 0;
    _program.write(_clutBinding, 0, gs.raster.residentClut);
    _resetOrdering();
    _begin();
    gs.residentSink = this;
  }

  /// Copies the memory back into the Gs and leaves the work to it.
  void detach() {
    sync();
    if (identical(gs.residentSink, this)) gs.residentSink = null;
    _program.dispose();
  }

  /// Runs all work, waits for it, and copies the local memory and the
  /// current CLUT into the Gs.
  void sync() {
    finish();
    _program.read(_vramBinding, 0, gs.mem.words);
    final clut = Uint32List(512);
    _program.read(_clutBinding, _version * 2048, clut);
    gs.raster.residentClut = clut;
  }

  void _resetOrdering() {
    _group = 1;
    _groupCount = 0;
    _pendingCount = 0;
    _pendingGeneration++;
    _clutStamp.fillRange(0, 512, 0);
    _groupReads.clear();
    _pendingReads.clear();
    _batchCount = 0;
    _batchWrites.clear();
    _batchReads.clear();
    _batchSnap.clear();
    _batchUsesZ = false;
    _uploading = false;
    _lastRegs.fillRange(0, _lastRegs.length, -1);
  }

  @override
  void primitive(int type, int attrs, List<GsVertex> vertices) =>
      _primitive(type, attrs, vertices);

  void _begin() {
    _stateAt = -1;
    _primCount = 0;
    _dataLength = 0;
    // step 0 is the setup of all primitives of the run
    _stepCount = 1;
  }

  int _allocData(int words) {
    final at = _dataLength;
    _dataLength += words;
    if (_dataLength > _dataWords) throw StateError('data overflow');
    return at;
  }

  void _step(int kind, int x, int y, List<int> params) {
    if (_stepCount >= _maxSteps) _submit();
    final k = _stepCount++;
    _steps
      ..[k * 4] = kind
      ..[k * 4 + 1] = x
      ..[k * 4 + 2] = y
      ..[k * 4 + 3] = 1;
    _params.setAll(k * 64, params);
    _count(stepCounts, _entryPoints[kind]);
  }

  /// a step over [n] threads of 256
  void _linearStep(int kind, int n, List<int> params) {
    final groups = (n + 255) >> 8;
    if (groups == 0) return;
    final x = groups < 65535 ? groups : 65535;
    _step(kind, x, (groups + x - 1) ~/ x, params);
  }

  void _submit({bool wait = true}) {
    if (_stepCount <= 1 && _primCount == 0) return;
    _steps
      ..[0] = _setup
      ..[1] = (_primCount + 63) >> 6
      ..[2] = 1
      ..[3] = 1;
    _params
      ..[0] = 0
      ..[1] = _primCount;
    final clock = Stopwatch()..start();
    _program
      ..write(_primBinding, 0, _prims, 0, _primCount * primWords)
      ..write(_dataBinding, 0, _data, 0, _dataLength)
      ..run(_steps, _stepCount, _params, wait: wait);
    gpuMs += clock.elapsedMicroseconds / 1000;
    submits++;
    _begin();
  }

  /// Runs all work and waits for it.
  void finish() {
    _close(materialize: true);
    _submit();
  }

  // ---- page footprints ----

  void _markRect(
      _Pages set, int psm, int bp, int bw, int x0, int y0, int x1, int y1) {
    final layout = gs.mem.layout(psm);
    final pages = layout.pagesInRow(bw);
    final xb = layout.xBits, yb = layout.yBits;
    final base = bp >> 5, spill = bp & 31 != 0;
    for (var py = y0 >> yb; py <= y1 >> yb; py++) {
      for (var px = x0 >> xb; px <= x1 >> xb; px++) {
        final page = base + py * pages + px;
        set.add(page);
        if (spill) set.add(page + 1);
      }
    }
  }

  // ---- CLUT versions ----

  final _clutSource = Uint32List(512);
  final _clutStamp = Int32List(512);
  // the entries loaded since the last version, each once
  final _pendingEntries = Int32List(512);
  int _pendingCount = 0;
  final _pendingMark = Int32List(512);
  int _pendingGeneration = 1;
  int _group = 1;
  int _version = 0, _groupFirst = 0, _groupCount = 0, _groupBase = 0;
  final _descriptors = Uint32List(_versions * 512);
  final _groupReads = _Pages(), _pendingReads = _Pages();

  @override
  void loadClut(int entry, int psm, int index) {
    _clutSource[entry] = 0x80000000 | psm << 24 | index;
    if (_pendingMark[entry] != _pendingGeneration) {
      _pendingMark[entry] = _pendingGeneration;
      _pendingEntries[_pendingCount++] = entry;
    }
    _clutStamp[entry] = _group;
    if (psm != _clutPsm) {
      _clutPsm = psm;
      _clutShift = gs.mem.layout(psm).unitShift + 11;
    }
    final page = (index >> _clutShift) & 511;
    if (_batchWrites.has(page)) _close(materialize: false);
    _pendingReads.add(page);
  }

  int _clutPsm = -1, _clutShift = 0;

  void _materialize() {
    if (_pendingCount == 0) return;
    if (_groupCount == _versions - 1) _close(materialize: false);
    if (_groupCount == 0) {
      _groupBase = _version;
      _groupFirst = (_version + 1) & (_versions - 1);
    }
    final at = _groupCount * 512;
    for (var e = 0; e < 512; e++) {
      _descriptors[at + e] = _clutStamp[e] == _group ? _clutSource[e] : 0;
    }
    _groupCount++;
    _version = (_version + 1) & (_versions - 1);
    _pendingCount = 0;
    _pendingGeneration++;
    _groupReads.addAll(_pendingReads);
    _pendingReads.clear();
  }

  void _emitGroup() {
    if (_groupCount == 0) return;
    final at = _allocData(_groupCount * 512);
    _data.setRange(at, at + _groupCount * 512, _descriptors);
    _step(_clut, _groupCount, 1, [_groupFirst, _groupCount, at, _groupBase]);
    _groupCount = 0;
    _group++;
    // loads after the batch stay for the next group
    for (var i = 0; i < _pendingCount; i++) {
      _clutStamp[_pendingEntries[i]] = _group;
    }
    _groupReads.clear();
  }

  // ---- raster batch ----

  final _batchWrites = _Pages(), _batchReads = _Pages(), _batchSnap = _Pages();
  int _batchFirst = 0, _batchCount = 0;
  int _batchFrame = -1, _batchZ = -1;
  bool _batchUsesZ = false;
  int _bx0 = 0, _by0 = 0, _bx1 = 0, _by1 = 0;

  void _emitBatch() {
    if (_batchCount == 0) return;
    if (_batchSnap.any) {
      final pages = _batchSnap.pages.toList();
      final at = _allocData(pages.length);
      _data.setAll(at, pages);
      _step(_snapshot, pages.length, 1, [at, pages.length]);
    }
    final frame = _batchFrame, zbuf = _batchZ;
    final fbp = (frame & 0x1ff) * 32, fbw = frame >> 16 & 0x3f;
    final fpsm = frame >> 24 & 0x3f;
    final zbp = (zbuf & 0x1ff) * 32, zpsm = 0x30 | (zbuf >> 24 & 0xf);
    final x0 = _bx0 & ~15, y0 = _by0 & ~15;
    _step(_raster, ((_bx1 - x0) >> 4) + 1, ((_by1 - y0) >> 4) + 1, [
      _batchFirst, _batchCount, x0, y0, //
      fbp, gs.mem.layout(fpsm).pagesInRow(fbw), fpsm, _batchUsesZ ? 1 : 0,
      zbp, gs.mem.layout(zpsm).pagesInRow(fbw), zpsm, 0,
    ]);
    _batchCount = 0;
    _batchWrites.clear();
    _batchReads.clear();
    _batchSnap.clear();
    _batchUsesZ = false;
  }

  /// Emits the open group and batch. [materialize] first turns the loads
  /// since the last version into one, for an access that must follow them.
  void _close({required bool materialize}) {
    if (materialize) _materialize();
    _emitGroup();
    _emitBatch();
  }

  // ---- states ----

  final _lastRegs = Int64List(20)..fillRange(0, 20, -1);
  int _stateAt = -1;

  int _state(int attrs) {
    final c = gs.contexts[attrs >> 9 & 1];
    final regs = [
      c.frame, c.zbuf, c.test, c.alpha, c.fba, c.xyoffset, c.scissor, c.tex0,
      c.tex1, c.clamp, c.miptbp1, c.miptbp2, gs.texa, gs.fogcol, gs.pabe,
      gs.colclamp, gs.dthe, gs.dimx, attrs & 0x3f8, //
    ];
    var same = _stateAt >= 0 && _stateAt + stateWords <= _dataLength;
    for (var i = 0; same && i < regs.length; i++) {
      if (_lastRegs[i] != regs[i]) same = false;
    }
    if (same) return _stateAt;
    _lastRegs.setAll(0, regs);
    final at = _allocData(stateWords);
    final s = _data;
    s.fillRange(at, at + stateWords, 0);
    final mem = gs.mem;
    final frame = c.frame, zbuf = c.zbuf;
    final fbw = frame >> 16 & 0x3f, fpsm = frame >> 24 & 0x3f;
    final zpsm = 0x30 | (zbuf >> 24 & 0xf);
    s[at + 0] = (frame & 0x1ff) * 32;
    s[at + 1] = mem.layout(fpsm).pagesInRow(fbw);
    s[at + 2] = fpsm;
    s[at + 3] = GsPsm.colorFormat(fpsm);
    s[at + 4] = frame >> 32 & 0xffffffff;
    s[at + 5] = c.fba & 1;
    s[at + 6] = (zbuf & 0x1ff) * 32;
    s[at + 7] = mem.layout(zpsm).pagesInRow(fbw);
    s[at + 8] = zpsm;
    s[at + 9] = zbuf >> 32 & 1;
    s[at + 10] = switch (zpsm) {
      GsPsm.z24 => 0xffffff,
      GsPsm.z16 || GsPsm.z16s => 0xffff,
      _ => 0xffffffff,
    };
    s[at + 11] = c.xyoffset & 0xffff;
    s[at + 12] = c.xyoffset >> 32 & 0xffff;
    final sc = c.scissor;
    s[at + 13] = sc & 0x7ff;
    s[at + 14] = sc >> 16 & 0x7ff;
    s[at + 15] = sc >> 32 & 0x7ff;
    s[at + 16] = sc >> 48 & 0x7ff;
    s[at + 17] = c.test & 0xffffffff;
    s[at + 18] = c.alpha & 0xff;
    s[at + 19] = c.alpha >> 32 & 0xff;
    s[at + 20] = gs.pabe & 1;
    s[at + 21] = gs.colclamp & 1;
    s[at + 22] = gs.dthe;
    s[at + 23] = gs.dimx & 0xffffffff;
    s[at + 24] = gs.dimx >> 32 & 0xffffffff;
    s[at + 25] = gs.fogcol & 0xffffff;
    if (attrs & 0x10 != 0) _textureState(s, at, c);
    _stateAt = at;
    return at;
  }

  void _textureState(Uint32List s, int at, GsContext c) {
    final mem = gs.mem;
    final t0 = c.tex0, t1 = c.tex1;
    final tbp = t0 & 0x3fff, tbw = t0 >> 14 & 0x3f, tpsm = t0 >> 20 & 0x3f;
    final tw = (t0 >> 26 & 15) < 10 ? t0 >> 26 & 15 : 10;
    final th = (t0 >> 30 & 15) < 10 ? t0 >> 30 & 15 : 10;
    final cpsm = switch (t0 >> 51 & 15) {
      0 => GsPsm.ct32,
      1 => GsPsm.ct24,
      0xa => GsPsm.ct16s,
      _ => GsPsm.ct16,
    };
    final csa = t0 >> 56 & 31;
    s[at + 27] = tpsm;
    s[at + 28] = GsPsm.colorFormat(tpsm);
    s[at + 29] = t0 >> 34 & 1;
    s[at + 30] = t0 >> 35 & 3;
    s[at + 31] = cpsm;
    s[at + 32] = GsPsm.bits(cpsm) == 16
        ? csa * 16
        : GsPsm.pixelBits(tpsm) == 4
            ? (csa & 15) * 16
            : 0;
    final cl = c.clamp;
    s[at + 33] = cl & 3;
    s[at + 34] = cl >> 2 & 3;
    s[at + 35] = cl >> 4 & 0x3ff;
    s[at + 36] = cl >> 14 & 0x3ff;
    s[at + 37] = cl >> 24 & 0x3ff;
    s[at + 38] = cl >> 34 & 0x3ff;
    final linear = t1 >> 5 & 1 != 0;
    s[at + 39] = linear ? 1 : 0;
    s[at + 40] = gs.texa & 0xff;
    s[at + 41] = gs.texa >> 32 & 0xff;
    s[at + 42] = gs.texa >> 15 & 1;
    final mxl = (t1 >> 2 & 7) < 6 ? t1 >> 2 & 7 : 6;
    final mmin = t1 >> 6 & 7;
    final minLinear = mmin == 1 || mmin >= 4;
    final mipmap = minLinear != linear || mxl > 0 && mmin >= 2;
    s[at + 43] = t1 & 1;
    s[at + 44] = mipmap ? 1 : 0;
    s[at + 45] = mxl;
    s[at + 46] = mmin;
    s[at + 47] = t1 >> 19 & 3;
    _dataFloats[at + 48] = (t1 >> 32 & 0xfff).toSigned(12) / 16;
    final layout = mem.layout(tpsm);
    final tbps = [tbp],
        pages = [layout.pagesInRow(tbw)],
        tws = [tw],
        ths = [th];
    if (mipmap && mxl > 0) {
      final auto = t1 >> 9 & 1 != 0;
      var w = tbw;
      for (var n = 1; n <= mxl; n++) {
        tws.add(tws[n - 1] - 1 > 0 ? tws[n - 1] - 1 : 0);
        ths.add(ths[n - 1] - 1 > 0 ? ths[n - 1] - 1 : 0);
        if (auto && n <= 3) {
          final words =
              ((1 << tws[n - 1]) * (1 << ths[n - 1]) * GsPsm.bits(tpsm)) >> 5;
          tbps.add((tbps[n - 1] + (words >> 6)) & 0x3fff);
          w = w >> 1 > 1 ? w >> 1 : 1;
        } else {
          final reg = n <= 3 ? c.miptbp1 : c.miptbp2;
          final f = reg >> (((n - 1) % 3) * 20);
          tbps.add(f & 0x3fff);
          w = f >> 14 & 0x3f;
        }
        pages.add(layout.pagesInRow(w));
      }
    }
    for (var n = 0; n < tbps.length; n++) {
      s[at + 49 + n] = tbps[n];
      s[at + 56 + n] = pages[n];
      s[at + 63 + n] = tws[n];
      s[at + 70 + n] = ths[n];
    }
  }

  // ---- primitives ----

  final _tex = _Pages(), _target = _Pages();

  void _primitive(int type, int attrs, List<GsVertex> v) {
    draws++;
    final kind = switch (type) {
      Gs.primPoint => 3,
      Gs.primTriangle => 1,
      Gs.primSprite => 2,
      _ => 4,
    };
    _materialize();
    final c = gs.contexts[attrs >> 9 & 1];
    final ofx = c.xyoffset & 0xffff, ofy = c.xyoffset >> 32 & 0xffff;
    final sc = c.scissor;
    final sx0 = sc & 0x7ff, sx1 = sc >> 16 & 0x7ff;
    final sy0 = sc >> 32 & 0x7ff, sy1 = sc >> 48 & 0x7ff;
    int x0, y0, x1, y1;
    if (kind == 4) {
      final ax = v[0].x - ofx, bx = v[1].x - ofx;
      final ay = v[0].y - ofy, by = v[1].y - ofy;
      if (ax == bx && ay == by) return;
      x0 = (ax < bx ? ax : bx) >> 4;
      x1 = (ax < bx ? bx : ax) >> 4;
      y0 = (ay < by ? ay : by) >> 4;
      y1 = (ay < by ? by : ay) >> 4;
    } else if (kind == 3) {
      x0 = x1 = (v[0].x - ofx) >> 4;
      y0 = y1 = (v[0].y - ofy) >> 4;
      if (x0 < sx0 || x0 > sx1 || y0 < sy0 || y0 > sy1) return;
    } else if (kind == 2) {
      final ax = v[0].x - ofx, bx = v[1].x - ofx;
      final ay = v[0].y - ofy, by = v[1].y - ofy;
      final left = ax < bx ? ax : bx, right = ax < bx ? bx : ax;
      final top = ay < by ? ay : by, bottom = ay < by ? by : ay;
      if (left == right || top == bottom) return;
      x0 = (left + 15) >> 4;
      y0 = (top + 15) >> 4;
      x1 = (right - 1) >> 4;
      y1 = (bottom - 1) >> 4;
    } else {
      var minx = v[0].x, maxx = minx, miny = v[0].y, maxy = miny;
      for (var k = 1; k < 3; k++) {
        if (v[k].x < minx) minx = v[k].x;
        if (v[k].x > maxx) maxx = v[k].x;
        if (v[k].y < miny) miny = v[k].y;
        if (v[k].y > maxy) maxy = v[k].y;
      }
      if (maxx - minx >= 32768 || maxy - miny >= 32768) {
        _count(unsupported, 'large triangle');
        return;
      }
      final area = (v[1].x - v[0].x) * (v[2].y - v[0].y) -
          (v[1].y - v[0].y) * (v[2].x - v[0].x);
      if (area == 0) return;
      x0 = (minx - ofx) >> 4;
      y0 = (miny - ofy) >> 4;
      x1 = (maxx - ofx + 15) >> 4;
      y1 = (maxy - ofy + 15) >> 4;
    }
    if (x0 < sx0) x0 = sx0;
    if (y0 < sy0) y0 = sy0;
    if (x1 > sx1) x1 = sx1;
    if (y1 > sy1) y1 = sy1;
    if (x0 > x1 || y0 > y1) return;

    final frame = c.frame & 0x3f3f01ff, zbuf = c.zbuf & 0x0f0001ff;
    final test = c.test;
    final zread = test >> 16 & 1 != 0 && test >> 17 & 3 >= 2;
    final zwrite = c.zbuf >> 32 & 1 == 0;
    final usesZ = zread || zwrite;
    final fbw = frame >> 16 & 0x3f, fpsm = frame >> 24 & 0x3f;
    _target.clear();
    _markRect(_target, fpsm, (frame & 0x1ff) * 32, fbw, x0, y0, x1, y1);
    if (usesZ) {
      _markRect(_target, 0x30 | (zbuf >> 24 & 0xf), (zbuf & 0x1ff) * 32, fbw,
          x0, y0, x1, y1);
    }
    _tex.clear();
    if (attrs & 0x10 != 0) _textureFootprint(c, attrs, v);

    if (_batchCount > 0 &&
        (frame != _batchFrame ||
            usesZ && _batchUsesZ && zbuf != _batchZ ||
            _tex.meets(_batchWrites) ||
            _target.meets(_batchReads))) {
      _close(materialize: false);
      // nothing of this run is open here, so the GPU can start on it
      if (chunkSteps > 0 && _stepCount >= chunkSteps && !_uploading) {
        _submit(wait: false);
      }
    }
    final snap = _tex.meets(_target);
    if (snap) _batchSnap.addAll(_tex);
    if (_batchCount == 0) {
      _batchFirst = _primCount;
      _batchFrame = frame;
      _batchZ = zbuf;
      _bx0 = x0;
      _by0 = y0;
      _bx1 = x1;
      _by1 = y1;
    } else {
      if (x0 < _bx0) _bx0 = x0;
      if (y0 < _by0) _by0 = y0;
      if (x1 > _bx1) _bx1 = x1;
      if (y1 > _by1) _by1 = y1;
    }
    if (usesZ) {
      _batchUsesZ = true;
      _batchZ = zbuf;
    }
    _batchWrites.addAll(_target);
    _batchReads.addAll(_tex);
    _batchCount++;

    if (_primCount >= _maxPrims) throw StateError('too many primitives');
    final o = _primCount++ * primWords;
    final p = _prims;
    p[o] = kind | attrs << 8 | (snap ? 1 << 24 : 0);
    p[o + 1] = _state(attrs);
    p[o + 2] = _version;
    for (var k = 0; k < v.length; k++) {
      final q = o + 3 + k * 8, w = v[k];
      p[q] = (w.x & 0xffff) | (w.y & 0xffff) << 16;
      p[q + 1] = w.z & 0xffffffff;
      p[q + 2] = (w.r & 0xff) |
          (w.g & 0xff) << 8 |
          (w.b & 0xff) << 16 |
          (w.a & 0xff) << 24;
      p[q + 3] = w.f & 0xff;
      p[q + 4] = (w.u & 0xffff) | (w.v & 0xffff) << 16;
      _primFloats[q + 5] = w.s;
      _primFloats[q + 6] = w.t;
      _primFloats[q + 7] = w.q;
    }
  }

  void _textureFootprint(GsContext c, int attrs, List<GsVertex> v) {
    final t0 = c.tex0, t1 = c.tex1;
    final tbp = t0 & 0x3fff, tbw = t0 >> 14 & 0x3f, tpsm = t0 >> 20 & 0x3f;
    final tw = (t0 >> 26 & 15) < 10 ? t0 >> 26 & 15 : 10;
    final th = (t0 >> 30 & 15) < 10 ? t0 >> 30 & 15 : 10;
    final cl = c.clamp;
    final wms = cl & 3, wmt = cl >> 2 & 3;
    final minu = cl >> 4 & 0x3ff, maxu = cl >> 14 & 0x3ff;
    final minv = cl >> 24 & 0x3ff, maxv = cl >> 34 & 0x3ff;
    final mxl = (t1 >> 2 & 7) < 6 ? t1 >> 2 & 7 : 6;
    final mmin = t1 >> 6 & 7;
    final mipmap =
        (mmin == 1 || mmin >= 4) != (t1 >> 5 & 1 != 0) || mxl > 0 && mmin >= 2;
    // texel ranges of level 0
    var u0 = 0, u1 = (1 << tw) - 1, w0 = 0, w1 = (1 << th) - 1;
    if (attrs & 0x100 != 0 && !mipmap) {
      var lo = v[0].u, hi = lo, vlo = v[0].v, vhi = vlo;
      for (final w in v) {
        if (w.u < lo) lo = w.u;
        if (w.u > hi) hi = w.u;
        if (w.v < vlo) vlo = w.v;
        if (w.v > vhi) vhi = w.v;
      }
      (u0, u1) = _range((lo >> 4) - 1, (hi >> 4) + 1, wms, tw, minu, maxu);
      (w0, w1) = _range((vlo >> 4) - 1, (vhi >> 4) + 1, wmt, th, minv, maxv);
    } else {
      (u0, u1) = _range(-1, 1 << 20, wms, tw, minu, maxu);
      (w0, w1) = _range(-1, 1 << 20, wmt, th, minv, maxv);
    }
    _markRect(_tex, tpsm, tbp, tbw, u0, w0, u1, w1);
    if (!mipmap || mxl == 0) return;
    final auto = t1 >> 9 & 1 != 0;
    var bp = tbp, w = tbw, lw = tw, lh = th;
    for (var n = 1; n <= mxl; n++) {
      final pw = lw, ph = lh;
      lw = lw > 0 ? lw - 1 : 0;
      lh = lh > 0 ? lh - 1 : 0;
      if (auto && n <= 3) {
        bp = (bp + ((((1 << pw) * (1 << ph) * GsPsm.bits(tpsm)) >> 5) >> 6)) &
            0x3fff;
        w = w >> 1 > 1 ? w >> 1 : 1;
      } else {
        final f = (n <= 3 ? c.miptbp1 : c.miptbp2) >> (((n - 1) % 3) * 20);
        bp = f & 0x3fff;
        w = f >> 14 & 0x3f;
      }
      _markRect(_tex, tpsm, bp, w, 0, 0, (1 << lw) - 1, (1 << lh) - 1);
    }
  }

  /// the texels a range [lo, hi] reads with wrap [mode]
  static (int, int) _range(
      int lo, int hi, int mode, int bits, int min, int max) {
    final size = 1 << bits;
    switch (mode) {
      case 0:
        return lo < 0 || hi >= size ? (0, size - 1) : (lo, hi);
      case 1:
        return (
          lo < 0 ? 0 : (lo >= size ? size - 1 : lo),
          hi < 0 ? 0 : (hi >= size ? size - 1 : hi)
        );
      case 2:
        return (
          lo < min ? min : (lo > max ? max : lo),
          hi < min ? min : (hi > max ? max : hi)
        );
      default:
        return (max, min | max);
    }
  }

  // ---- transfers ----

  int _uploadPsm = 0, _uploadBp = 0, _uploadBw = 0, _uploadX = 0;
  int _uploadY = 0, _uploadW = 0, _uploadH = 0, _uploadBits = 0;
  int _uploadAt = 0, _uploadWords = 0, _uploadReceived = 0;
  bool _uploading = false;

  @override
  void beginUpload(
      int psm, int base, int bufferWidth, int x, int y, int width, int height) {
    if (_uploading) _endUpload();
    _uploadPsm = psm;
    _uploadBp = base;
    _uploadBw = bufferWidth;
    _uploadX = x;
    _uploadY = y;
    _uploadW = width;
    _uploadH = height;
    _uploadBits = GsPsm.pixelBits(psm);
    _uploadWords = (width * height * _uploadBits + 31) >> 5;
    _uploadReceived = 0;
    _uploading = _uploadWords > 0;
    if (_uploading) _uploadAt = _allocData(_uploadWords);
  }

  @override
  bool uploadWord(int word) {
    if (!_uploading) {
      _count(unsupported, 'upload word without a transfer');
      return true;
    }
    _data[_uploadAt + _uploadReceived++] = word;
    if (_uploadReceived < _uploadWords) return false;
    _endUpload();
    return true;
  }

  void _endUpload() {
    _uploading = false;
    final pixels = (_uploadReceived * 32) ~/ _uploadBits;
    final total = _uploadW * _uploadH;
    final n = pixels < total ? pixels : total;
    if (n == 0) return;
    final rows = (n + _uploadW - 1) ~/ _uploadW;
    final writes = _Pages();
    _markWrapped(writes, _uploadPsm, _uploadBp, _uploadBw, _uploadX, _uploadY,
        _uploadW, rows);
    _beforeWrite(writes, null);
    _linearStep(_upload, n, [
      _uploadPsm, _uploadBp, _uploadBw, _uploadX | _uploadY << 16, //
      _uploadW, n, _uploadAt, _uploadBits,
    ]);
    if (n < total) _count(unsupported, 'partial upload');
  }

  void _markWrapped(
      _Pages set, int psm, int bp, int bw, int x, int y, int w, int h) {
    final x1 = x + w - 1, y1 = y + h - 1;
    _markRect(set, psm, bp, bw, x1 > 2047 ? 0 : x, y1 > 2047 ? 0 : y,
        x1 > 2047 ? 2047 : x1, y1 > 2047 ? 2047 : y1);
  }

  /// Orders a write to [writes] (and a read of [reads]) after the open work
  /// that touches those pages.
  void _beforeWrite(_Pages writes, _Pages? reads) {
    if (writes.meets(_batchReads) ||
        writes.meets(_batchWrites) ||
        writes.meets(_groupReads) ||
        writes.meets(_pendingReads) ||
        (reads != null && reads.meets(_batchWrites))) {
      _close(materialize: true);
    }
  }

  @override
  void copyLocal(int bitbltbuf, int trxpos, int trxreg) {
    final sbp = bitbltbuf & 0x3fff, sbw = bitbltbuf >> 16 & 0x3f;
    final spsm = bitbltbuf >> 24 & 0x3f;
    final dbp = bitbltbuf >> 32 & 0x3fff, dbw = bitbltbuf >> 48 & 0x3f;
    final dpsm = bitbltbuf >> 56 & 0x3f;
    final sx = trxpos & 0x7ff, sy = trxpos >> 16 & 0x7ff;
    final dx = trxpos >> 32 & 0x7ff, dy = trxpos >> 48 & 0x7ff;
    final w = trxreg & 0xfff, h = trxreg >> 32 & 0xfff;
    if (w == 0 || h == 0) return;
    final reads = _Pages(), writes = _Pages();
    _markWrapped(reads, spsm, sbp, sbw, sx, sy, w, h);
    _markWrapped(writes, dpsm, dbp, dbw, dx, dy, w, h);
    _beforeWrite(writes, reads);
    final pages = reads.pages.toList();
    final at = _allocData(pages.length);
    _data.setAll(at, pages);
    _step(_snapshot, pages.length, 1, [at, pages.length]);
    _linearStep(_copy, w * h, [
      spsm, sbp, sbw, sx | sy << 16, //
      dpsm, dbp, dbw, dx | dy << 16,
      w, h,
    ]);
  }

  @override
  void beginDownload(
      int psm, int base, int bufferWidth, int x, int y, int width, int height) {
    sync();
    _count(unsupported, 'download (synchronous)');
  }

  @override
  void vblank(int field) => sync();
}
