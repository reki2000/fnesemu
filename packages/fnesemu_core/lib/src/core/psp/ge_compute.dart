// The compute GE: takes the draws of a PspGe after its vertex stage, and
// rasterizes them with the program in ge_compute_shader.dart on the GPU of
// a ComputeSink, where the video memory stays resident.
//
// Work: the draws are recorded, not sent one by one. The draws with the
// same frame and depth buffers form a batch, binned into 16x16 tiles on the
// host, and a batch is one dispatch in which each thread owns two pixels
// and runs the draws of its tile in order. A submit sends the recorded
// batches at once. It happens at the end of a frame, when the buffers are
// full, and when the CPU needs the video memory.
//
// Memory: while attached, the GPU owns the video memory. Each 4 KiB page
// is in one of three states: synced (both copies equal), GPU newer (a
// recorded draw writes it) or CPU dirty (the CPU wrote it since the last
// submit). A CPU access to a GPU newer page reads all such pages back
// first, which is the only wait. A CPU write to a synced page submits the
// recorded work first, so that it sees the page as it was, and the page is
// uploaded at the next submit. The JIT maps the pages to match: synced
// pages for reads, CPU dirty pages for both, GPU newer pages not at all.
//
// Textures in main memory are copied into the submit with the draw, once
// per submit while their bytes stay the same. Textures in video memory are
// read on the GPU; a batch closes when a draw reads a page that the batch
// writes, or writes a page that the batch reads.
//
// Display: at the end of each frame the frame buffer is copied without
// waiting, and the picture of the previous frame is shown, one frame late.
import 'dart:typed_data';

import '../../compute_sink.dart';
import 'ge_compute_shader.dart';
import 'memory.dart';

const _primWords = 36;
const _maxPrims = 65536;
const _dataWords = 8 * 1024 * 1024;
const _maxBatches = 4096;
const _paramWords = 64;
const _tilesX = 64, _tilesY = 32;
const _maxNodes = 1 << 21;

/// the data words a draw may need besides its texture and palette: the
/// state block and the tile entries of the most tiles it can cover
const _drawMargin = stateWords + _tilesX * _tilesY * 5;

/// the number of words of a draw state; the layout is in the shader
const stateWords = 24;

const _pageShift = 12;
const _pages = PspMemory.vramSize >> _pageShift;

const _bindings = [
  ComputeBinding(ComputeBindingKind.storage, PspMemory.vramSize),
  ComputeBinding(
      ComputeBindingKind.readOnlyStorage, _maxPrims * _primWords * 4),
  ComputeBinding(ComputeBindingKind.readOnlyStorage, _dataWords * 4),
  ComputeBinding(ComputeBindingKind.params, 64),
];
const _vramBinding = 0, _primBinding = 1, _dataBinding = 2;

/// Runs the rasterizer of a PspGe on a [ComputeSink].
class GeCompute implements PspVramGuard {
  /// Compiles the program on [sink]; throws if it cannot.
  GeCompute(this.mem, ComputeSink sink)
      : _program = sink.program(
            pspGeComputeShader, const ['raster', 'copy'], _bindings,
            paramStride: _paramWords * 4, maxDispatches: _maxBatches);

  final PspMemory mem;
  final ComputeProgram _program;

  /// Called when a page changes its state, for the JIT mappings.
  void Function(int page, int state)? onPage;

  // primitive kinds
  static const triangle = 0, sprite = 1, point = 2, clear = 3;

  // state words and flags the core sets; the others belong to the shader
  static const sFlags = 0, sTexBase = 11, sPalBase = 18, sPalCount = 19;
  static const fTexVram = 2048;
  static const fDepth = 8 | 16;

  /// counts for tools
  int draws = 0, submits = 0, syncs = 0, batches = 0, flushes = 0;
  int transfers = 0;
  int uploadedBytes = 0;

  /// the milliseconds spent in the sink, including the waits
  double gpuMs = 0;

  final _state = Uint8List(_pages);
  final _dirty = Uint32List(_pages);
  final _dirtyMark = Uint8List(_pages);
  int _dirtyCount = 0;

  late final _vramWords = Uint32List.sublistView(mem.vram);

  /// Copies the video memory to the GPU, takes the ownership of it and
  /// starts with no recorded work.
  void attach() {
    _takeDisplay();
    _displayed = false;
    _resetRecording();
    _program.write(_vramBinding, 0, _vramWords);
    _dirtyCount = 0;
    _dirtyMark.fillRange(0, _pages, 0);
    for (var p = 0; p < _pages; p++) {
      _setState(p, PspVramGuard.synced, force: true);
    }
    mem.vramPages = _state;
    mem.guard = this;
  }

  /// Copies the video memory back and leaves it to the CPU.
  void detach() {
    sync();
    mem.guard = null;
    mem.vramPages = null;
    for (var p = 0; p < _pages; p++) {
      _setState(p, PspVramGuard.cpuDirty, force: true);
    }
    _program.dispose();
  }

  /// Releases the program without copying the memory back.
  void dispose() => _program.dispose();

  void _setState(int page, int state, {bool force = false}) {
    if (!force && _state[page] == state) return;
    _state[page] = state;
    onPage?.call(page, state);
  }

  bool get _pending => _primCount != 0 || _dispatchCount != 0;

  // ---- the guard ----

  @override
  void access(int offset, bool write) {
    final page = offset >> _pageShift;
    if (_state[page] == PspVramGuard.gpuNewer) {
      sync();
    }
    if (write && _state[page] == PspVramGuard.synced) {
      // the recorded work reads the page as it is now
      if (_pending) {
        flushes++;
        _submit();
      }
      _markDirty(page);
      _setState(page, PspVramGuard.cpuDirty);
    }
  }

  void _markDirty(int page) {
    if (_dirtyMark[page] != 0) return;
    _dirtyMark[page] = 1;
    _dirty[_dirtyCount++] = page;
  }

  /// Runs all work, waits for it, and copies the pages the GPU wrote into
  /// the video memory of the core.
  void sync() => _syncPages(0, _pages - 1);

  /// Copies the pages the GPU wrote of the [bytes] at [addr], when they are
  /// in video memory, as [sync] does for all.
  void syncRange(int addr, int bytes) {
    final at = _vramOffset(addr);
    if (at < 0 || bytes <= 0) return;
    final end =
        at + bytes > PspMemory.vramSize ? PspMemory.vramSize : at + bytes;
    _syncPages(at >> _pageShift, (end - 1) >> _pageShift);
  }

  void _syncPages(int from, int to) {
    var first = _pages, last = -1;
    for (var p = from; p <= to; p++) {
      if (_state[p] == PspVramGuard.gpuNewer) {
        if (p < first) first = p;
        last = p;
      }
    }
    if (last < 0) return;
    _takeDisplay();
    _submit();
    syncs++;
    final clock = Stopwatch()..start();
    _program.read(
        _vramBinding,
        first << _pageShift,
        Uint32List.sublistView(
            mem.vram, first << _pageShift, (last + 1) << _pageShift));
    gpuMs += clock.elapsedMicroseconds / 1000;
    for (var p = first; p <= last; p++) {
      if (_state[p] == PspVramGuard.gpuNewer) {
        _setState(p, PspVramGuard.synced);
      }
    }
  }

  /// Takes the video memory of the core as it is now, after a state load or
  /// a reset that wrote it directly.
  void reload() {
    _takeDisplay();
    _displayed = false;
    _resetRecording();
    _dirtyCount = 0;
    _dirtyMark.fillRange(0, _pages, 0);
    _program.write(_vramBinding, 0, _vramWords);
    for (var p = 0; p < _pages; p++) {
      _setState(p, PspVramGuard.synced);
    }
  }

  // ---- the display ----

  final _display = Uint32List(1024 * 272);
  bool _displayed = false, _prefetched = false;
  int _prefetchAt = 0, _prefetchWords = 0;
  int _prefetchStride = 0, _prefetchFormat = 0;

  /// the frame buffer width and format of [display]
  int displayStride = 0, displayFormat = 0;

  /// Submits the work of the frame and starts to copy the frame buffer at
  /// [addr] of [stride] pixels in [format], at the end of a frame.
  void endFrame(int addr, int stride, int format) {
    _takeDisplay();
    _submit();
    final phys = PspMemory.physical(addr);
    if (phys < PspMemory.vramAt ||
        phys >= PspMemory.vramAt + PspMemory.vramMirrors) {
      return;
    }
    final at = (phys - PspMemory.vramAt) & (PspMemory.vramSize - 1);
    final bytes = stride * 272 * (format == 3 ? 4 : 2);
    if (at & 3 != 0 || bytes == 0 || at + bytes > PspMemory.vramSize) return;
    _program.prefetch(_vramBinding, at, bytes);
    _prefetched = true;
    _prefetchAt = at;
    _prefetchWords = bytes >> 2;
    _prefetchStride = stride;
    _prefetchFormat = format;
  }

  /// The frame buffer that was shown at the end of the frame before the
  /// last one, in words from its start, of [displayStride] pixels a line in
  /// [displayFormat]; null before the end of the second frame.
  Uint32List? get display => _displayed ? _display : null;

  void _takeDisplay() {
    if (!_prefetched) return;
    final clock = Stopwatch()..start();
    _program.read(_vramBinding, _prefetchAt,
        Uint32List.sublistView(_display, 0, _prefetchWords));
    gpuMs += clock.elapsedMicroseconds / 1000;
    _prefetched = false;
    _displayed = true;
    displayStride = _prefetchStride;
    displayFormat = _prefetchFormat;
  }

  // ---- recording ----

  final _prims = Uint32List(_maxPrims * _primWords);
  late final _primFloats = Float32List.view(_prims.buffer);
  final _data = Uint32List(_dataWords);
  final _dispatches = Uint32List(_maxBatches * 4);
  final _params = Uint32List(_maxBatches * _paramWords);
  int _primCount = 0, _dataLength = 0, _dispatchCount = 0;

  /// The state of the next draw, filled by the core before [setState].
  final state = Uint32List(stateWords);
  final _lastState = Uint32List(stateWords);
  int _stateAt = -1;

  // RAM texture copies of this submit: (address << 24 | bytes) to the data
  // word, and the list generation in which each was last checked
  final _textures = <int, int>{};
  final _textureChecked = <int, int>{};
  int _generation = 0;
  int _paletteVersion = -1, _paletteAt = 0;

  void _resetRecording() {
    _primCount = 0;
    _dataLength = 0;
    _dispatchCount = 0;
    _stateAt = -1;
    _textures.clear();
    _textureChecked.clear();
    _paletteVersion = -1;
    _clearBatch();
    _hasTarget = false;
  }

  /// Marks that main memory may have changed since the draws so far, as
  /// at the start of a list or after a callback or a transfer.
  void invalidateRam() => _generation++;

  // ---- the batch ----

  bool _hasTarget = false;
  // the texture in video memory of the next draw, or -1
  int _drawTexAt = -1, _drawTexBytes = 0;
  int _fbAt = 0, _fbWidth = 0, _format = 0, _zAt = 0, _zWidth = 0;
  int _maxY = 0;
  int _batchPrims = 0, _batchTileWords = 0;
  bool _batchDepth = false;
  int _fbY0 = 0, _fbY1 = 0, _zY0 = 0, _zY1 = 0;
  final _batchWrites = Uint32List(_pages), _batchReads = Uint32List(_pages);
  int _batchGeneration = 1;

  final _head = Int32List(_tilesX * _tilesY)
    ..fillRange(0, _tilesX * _tilesY, -1);
  final _tail = Int32List(_tilesX * _tilesY);
  final _tileCount = Uint32List(_tilesX * _tilesY);
  final _touched = Uint32List(_tilesX * _tilesY);
  int _touchedCount = 0;
  final _nodePrim = Uint32List(_maxNodes), _nodeNext = Int32List(_maxNodes);
  int _nodeCount = 0;

  void _clearBatch() {
    for (var i = 0; i < _touchedCount; i++) {
      final t = _touched[i];
      _head[t] = -1;
      _tileCount[t] = 0;
    }
    _touchedCount = 0;
    _nodeCount = 0;
    _batchPrims = 0;
    _batchTileWords = 0;
    _batchDepth = false;
    _fbY0 = _zY0 = 1 << 30;
    _fbY1 = _zY1 = -1;
    _batchGeneration++;
  }

  /// Selects the frame buffer at [fb] of [fbWidth] pixels in [format], the
  /// depth buffer at [z] of [zWidth] and the lines up to [maxY]. Returns
  /// false when the GPU cannot draw into them.
  bool target(int fb, int fbWidth, int format, int z, int zWidth, int maxY) {
    final fbAt = _vramOffset(fb);
    if (fbAt < 0 || fbAt & 3 != 0) return false;
    if (fbWidth <= 0 || fbWidth & 1 != 0 || fbWidth > _tilesX * 16) {
      return false;
    }
    if (maxY <= 0 || maxY > _tilesY * 16) return false;
    var zAt = 0;
    if (zWidth > 0) {
      zAt = _vramOffset(z);
      if (zAt < 0 || zAt & 3 != 0 || zWidth & 1 != 0) return false;
    }
    if (!_hasTarget ||
        _fbAt != fbAt ||
        _fbWidth != fbWidth ||
        _format != format ||
        _zAt != zAt ||
        _zWidth != zWidth ||
        _maxY != maxY) {
      _emitBatch();
      _hasTarget = true;
      _fbAt = fbAt;
      _fbWidth = fbWidth;
      _format = format;
      _zAt = zAt;
      _zWidth = zWidth;
      _maxY = maxY;
    }
    return true;
  }

  static int _vramOffset(int addr) {
    final phys = PspMemory.physical(addr);
    if (phys < PspMemory.vramAt ||
        phys >= PspMemory.vramAt + PspMemory.vramMirrors) {
      return -1;
    }
    return (phys - PspMemory.vramAt) & (PspMemory.vramSize - 1);
  }

  /// Takes [state] for the next draws. A texture is at [texture] with
  /// [textureBytes] bytes (0 for none), and an indexed one uses the
  /// [paletteCount] entries of [palette] of [paletteVersion]. Returns false
  /// when the GPU cannot draw with them.
  bool setState(int texture, int textureBytes, Uint32List palette,
      int paletteCount, int paletteVersion, bool indexed) {
    var need = _drawMargin + (indexed ? paletteCount : 0);
    final texPhys = PspMemory.physical(texture);
    final inRam = textureBytes > 0 &&
        texPhys >= PspMemory.ramAt &&
        texPhys < PspMemory.ramEnd;
    final texAt = textureBytes > 0 ? _vramOffset(texture) : -1;
    if (textureBytes > 0 && !inRam && texAt < 0) return false;
    if (inRam) {
      if (texPhys + textureBytes > PspMemory.ramEnd) return false;
      need += (textureBytes >> 2) + 2;
    }
    if (need > _dataWords ~/ 2) return false;
    reserve(need);
    _drawTexAt = texAt;
    _drawTexBytes = textureBytes;
    if (texAt >= 0) {
      state[sFlags] |= fTexVram;
      state[sTexBase] = texAt;
    } else if (inRam) {
      state[sTexBase] = _ramTexture(texPhys, textureBytes);
    }
    if (indexed) {
      if (paletteVersion != _paletteVersion) {
        _paletteAt = _dataLength;
        _data.setRange(_dataLength, _dataLength + paletteCount, palette);
        _dataLength += paletteCount;
        _paletteVersion = paletteVersion;
      }
      state[sPalBase] = _paletteAt;
      state[sPalCount] = paletteCount;
    }
    if (_stateAt < 0 || !_sameState()) {
      _stateAt = _dataLength;
      _data.setRange(_dataLength, _dataLength + stateWords, state);
      _lastState.setAll(0, state);
      _dataLength += stateWords;
    }
    return true;
  }

  /// Makes room for the next primitive and [words] of its data, submitting
  /// the recorded work when the buffers are full. A clear calls it instead
  /// of [setState].
  void reserve([int words = _drawMargin]) {
    _drawTexAt = -1;
    // a draw may close two batches: at its target and at its emit
    if (_primCount >= _maxPrims ||
        _dispatchCount >= _maxBatches - 2 ||
        _nodeCount + _tilesX * _tilesY > _maxNodes ||
        _dataLength + _batchTileWords + words > _dataWords) {
      _submit();
    }
  }

  bool _sameState() {
    for (var i = 0; i < stateWords; i++) {
      if (state[i] != _lastState[i]) return false;
    }
    return true;
  }

  /// The byte address in the data buffer of a copy of the texture at
  /// [phys] in main memory.
  int _ramTexture(int phys, int bytes) {
    final start = (phys - PspMemory.ramAt) & ~3;
    final words = ((phys - PspMemory.ramAt) + bytes - start + 3) >> 2;
    final key = phys << 24 | bytes;
    final at = _textures[key];
    if (at != null) {
      if (_textureChecked[key] == _generation) return at * 4 + (phys & 3);
      final ram = Uint32List.sublistView(mem.ram, start, start + words * 4);
      var same = true;
      for (var i = 0; i < words; i++) {
        if (_data[at + i] != ram[i]) {
          same = false;
          break;
        }
      }
      if (same) {
        _textureChecked[key] = _generation;
        return at * 4 + (phys & 3);
      }
    }
    final copy = _dataLength;
    _data.setRange(copy, copy + words,
        Uint32List.sublistView(mem.ram, start, start + words * 4));
    _dataLength += words;
    uploadedBytes += words * 4;
    _textures[key] = copy;
    _textureChecked[key] = _generation;
    return copy * 4 + (phys & 3);
  }

  bool _meets(Uint32List marks, int at, int bytes) {
    final first = at >> _pageShift, last = (at + bytes - 1) >> _pageShift;
    for (var p = first; p <= last; p++) {
      if (marks[p & (_pages - 1)] == _batchGeneration) return true;
    }
    return false;
  }

  void _mark(Uint32List marks, int at, int bytes) {
    final first = at >> _pageShift, last = (at + bytes - 1) >> _pageShift;
    for (var p = first; p <= last; p++) {
      marks[p & (_pages - 1)] = _batchGeneration;
    }
  }

  /// Writes vertex [slot] (0 to 2) of the next primitive.
  void vertex(int slot, double x, double y, double z, double su, double sv,
      double invW, double r, double g, double b, double a) {
    final at = _primCount * _primWords + 6 + slot * 10;
    _primFloats
      ..[at] = x
      ..[at + 1] = y
      ..[at + 2] = z
      ..[at + 3] = su
      ..[at + 4] = sv
      ..[at + 5] = invW
      ..[at + 6] = r
      ..[at + 7] = g
      ..[at + 8] = b
      ..[at + 9] = a;
  }

  /// Writes word [index] of the vertex words of the next primitive, for
  /// the layouts of sprites and clears.
  void word(int index, int value) =>
      _prims[_primCount * _primWords + 6 + index] = value;

  /// Writes float [index] of the vertex words of the next primitive.
  void float(int index, double value) =>
      _primFloats[_primCount * _primWords + 6 + index] = value;

  /// Records the next primitive of [kind] over the pixels [x0, x1) x
  /// [y0, y1), with the vertices written before. [depth] tells whether it
  /// reads or writes the depth buffer.
  void emit(int kind, int x0, int y0, int x1, int y1, bool depth) {
    if (x1 <= x0 || y1 <= y0) return;
    final rowBytes = _fbWidth * (_format == 3 ? 4 : 2);
    // A draw that reads pages the batch writes, or writes pages the batch
    // reads, starts a batch.
    final fbFrom = _fbAt + y0 * rowBytes, fbBytes = (y1 - y0) * rowBytes;
    final zFrom = _zAt + y0 * _zWidth * 2, zBytes = (y1 - y0) * _zWidth * 2;
    final texAt = _drawTexAt;
    if (_batchPrims != 0 &&
        (texAt >= 0 && _meets(_batchWrites, texAt, _drawTexBytes) ||
            _meets(_batchReads, fbFrom, fbBytes) ||
            depth && _meets(_batchReads, zFrom, zBytes))) {
      _emitBatch();
    }
    if (texAt >= 0) _mark(_batchReads, texAt, _drawTexBytes);
    final at = _primCount * _primWords;
    _prims
      ..[at] = kind
      ..[at + 1] = _stateAt
      ..[at + 2] = x0
      ..[at + 3] = y0
      ..[at + 4] = x1
      ..[at + 5] = y1;
    if (y0 < _fbY0 || y1 > _fbY1) {
      _written(_fbAt, rowBytes, y0, y1, _fbY0, _fbY1);
      if (y0 < _fbY0) _fbY0 = y0;
      if (y1 > _fbY1) _fbY1 = y1;
    }
    if (depth) {
      _batchDepth = true;
      if (y0 < _zY0 || y1 > _zY1) {
        _written(_zAt, _zWidth * 2, y0, y1, _zY0, _zY1);
        if (y0 < _zY0) _zY0 = y0;
        if (y1 > _zY1) _zY1 = y1;
      }
    }
    final tx0 = x0 >> 4, tx1 = (x1 - 1) >> 4;
    final ty0 = y0 >> 4, ty1 = (y1 - 1) >> 4;
    final prim = _primCount++;
    for (var ty = ty0; ty <= ty1; ty++) {
      for (var tx = tx0; tx <= tx1; tx++) {
        final t = ty * _tilesX + tx;
        final node = _nodeCount++;
        _nodePrim[node] = prim;
        _nodeNext[node] = -1;
        if (_head[t] < 0) {
          _head[t] = node;
          _touched[_touchedCount++] = t;
          _batchTileWords += 4;
        } else {
          _nodeNext[_tail[t]] = node;
        }
        _tail[t] = node;
        _tileCount[t]++;
        _batchTileWords++;
      }
    }
    _batchPrims++;
    draws++;
  }

  /// Marks the pages of lines [y0, y1) of the buffer at [base] with [row]
  /// bytes a line as GPU newer, except for the lines [have0, have1) the
  /// batch has marked.
  void _written(int base, int row, int y0, int y1, int have0, int have1) {
    if (row == 0) return;
    void lines(int from, int to) {
      if (to <= from) return;
      final at = base + from * row, bytes = (to - from) * row;
      final first = at >> _pageShift, last = (at + bytes - 1) >> _pageShift;
      for (var p = first; p <= last; p++) {
        final page = p & (_pages - 1);
        _batchWrites[page] = _batchGeneration;
        if (_state[page] == PspVramGuard.cpuDirty) _markDirty(page);
        _setState(page, PspVramGuard.gpuNewer);
      }
    }

    if (have1 < 0) {
      lines(y0, y1);
    } else {
      lines(y0, have0 < y1 ? have0 : y1);
      lines(have1 > y0 ? have1 : y0, y1);
    }
  }

  void _emitBatch() {
    if (_batchPrims == 0) return;
    final n = _touchedCount;
    final table = _dataLength;
    var list = table + n * 4;
    for (var i = 0; i < n; i++) {
      final t = _touched[i];
      final count = _tileCount[t];
      _data
        ..[table + i * 4] = t % _tilesX
        ..[table + i * 4 + 1] = t ~/ _tilesX
        ..[table + i * 4 + 2] = list
        ..[table + i * 4 + 3] = count;
      for (var node = _head[t]; node >= 0; node = _nodeNext[node]) {
        _data[list++] = _nodePrim[node];
      }
    }
    _dataLength = list;
    final k = _dispatchCount++;
    final x = n < 65535 ? n : 65535;
    _dispatches
      ..[k * 4] = 0
      ..[k * 4 + 1] = x
      ..[k * 4 + 2] = (n + x - 1) ~/ x
      ..[k * 4 + 3] = 1;
    _params
      ..[k * _paramWords] = _fbAt
      ..[k * _paramWords + 1] = _fbWidth
      ..[k * _paramWords + 2] = _format
      ..[k * _paramWords + 3] = _zAt
      ..[k * _paramWords + 4] = _zWidth
      ..[k * _paramWords + 5] = _batchDepth ? 1 : 0
      ..[k * _paramWords + 6] = table
      ..[k * _paramWords + 7] = _maxY
      ..[k * _paramWords + 8] = n;
    batches++;
    _clearBatch();
  }

  /// Records a block transfer of [lines] lines of [lineBytes] bytes from
  /// [src] to [dst], [srcPitch] and [dstPitch] bytes a line apart. Returns
  /// false when the GPU cannot make it: the destination is not in video
  /// memory, the source is in neither memory, or the two overlap.
  bool transfer(
      int src, int srcPitch, int dst, int dstPitch, int lineBytes, int lines) {
    final dstAt = _vramOffset(dst);
    if (dstAt < 0 || lines <= 0 || lineBytes <= 0) return false;
    final dstBytes = (lines - 1) * dstPitch + lineBytes;
    final srcBytes = (lines - 1) * srcPitch + lineBytes;
    if (dstAt + dstBytes > PspMemory.vramSize) return false;
    final srcAt = _vramOffset(src);
    final srcPhys = PspMemory.physical(src);
    final inRam =
        srcPhys >= PspMemory.ramAt && srcPhys + srcBytes <= PspMemory.ramEnd;
    if (srcAt >= 0) {
      if (srcAt + srcBytes > PspMemory.vramSize ||
          srcAt < dstAt + dstBytes && dstAt < srcAt + srcBytes) {
        return false;
      }
    } else if (!inRam) {
      return false;
    }
    final need = inRam ? (srcBytes >> 2) + 2 : 0;
    if (need > _dataWords ~/ 2) return false;
    reserve(need);
    // in order after the draws so far
    _emitBatch();
    final from = inRam ? _ramTexture(srcPhys, srcBytes) : srcAt;
    final first = dstAt >> 2, words = ((dstAt + dstBytes + 3) >> 2) - first;
    final groups = (words + 63) >> 6;
    final x = groups < 65535 ? groups : 65535;
    final k = _dispatchCount++;
    _dispatches
      ..[k * 4] = 1
      ..[k * 4 + 1] = x
      ..[k * 4 + 2] = (groups + x - 1) ~/ x
      ..[k * 4 + 3] = 1;
    _params
      ..fillRange(k * _paramWords, k * _paramWords + 12, 0)
      ..[k * _paramWords] = dstAt
      ..[k * _paramWords + 1] = dstPitch
      ..[k * _paramWords + 2] = lineBytes
      ..[k * _paramWords + 3] = lines
      ..[k * _paramWords + 4] = from
      ..[k * _paramWords + 5] = srcPitch
      ..[k * _paramWords + 6] = inRam ? 0 : 1
      ..[k * _paramWords + 7] = words
      ..[k * _paramWords + 8] = first;
    for (var p = dstAt >> _pageShift;
        p <= (dstAt + dstBytes - 1) >> _pageShift;
        p++) {
      if (_state[p] == PspVramGuard.cpuDirty) _markDirty(p);
      _setState(p, PspVramGuard.gpuNewer);
    }
    transfers++;
    return true;
  }

  /// Uploads the pages the CPU wrote and sends the recorded work without
  /// waiting for it.
  void _submit() {
    _emitBatch();
    final clock = Stopwatch()..start();
    if (_dirtyCount != 0) {
      // upload the dirty pages as runs of consecutive pages
      final pages = Uint32List.sublistView(_dirty, 0, _dirtyCount)..sort();
      var i = 0;
      while (i < pages.length) {
        final first = pages[i];
        var last = first;
        while (i + 1 < pages.length && pages[i + 1] == last + 1) {
          last = pages[++i];
        }
        i++;
        _program.write(_vramBinding, first << _pageShift, _vramWords,
            first << (_pageShift - 2), (last + 1) << (_pageShift - 2));
      }
      for (final p in pages) {
        _dirtyMark[p] = 0;
        if (_state[p] == PspVramGuard.cpuDirty) {
          _setState(p, PspVramGuard.synced);
        }
      }
      _dirtyCount = 0;
    }
    if (_dispatchCount != 0) {
      _program
        ..write(_primBinding, 0, _prims, 0, _primCount * _primWords)
        ..write(_dataBinding, 0, _data, 0, _dataLength)
        ..run(_dispatches, _dispatchCount, _params, wait: false);
      submits++;
    }
    gpuMs += clock.elapsedMicroseconds / 1000;
    _resetRecording();
  }
}
