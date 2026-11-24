import 'dart:math' as math;
import 'dart:typed_data';

import '../../compute_sink.dart';
import 'bus.dart';
import 'rdp_compute_shader.dart';

class N64RdpRect {
  const N64RdpRect(this.address, this.stride, this.x, this.y, this.width,
      this.height, this.pixelBytes);

  final int address, stride, x, y, width, height, pixelBytes;

  int get start => address + (y * stride + x) * pixelBytes;
  int get end => start + ((height - 1) * stride + width) * pixelBytes;

  bool overlaps(int at, int size) {
    final first = start;
    if (at + size <= first || at >= end) return false;
    if (at <= first) return true;
    final pitch = stride * pixelBytes;
    final offset = (at - first) % pitch;
    return offset < width * pixelBytes || offset + size > pitch;
  }

  void writeFill(N64Bus bus, int color, {bool Function(int, int)? colorCommitted}) {
    final ram = bus.ramData, limit = bus.ram.length;
    for (var row = 0; row < height; row++) {
      var at = start + row * stride * pixelBytes;
      for (var col = 0; col < width; col++, at += pixelBytes) {
        if (at + pixelBytes > limit) break;
        if (colorCommitted?.call(x + col, y + row) ?? false) continue;
        if (pixelBytes == 4) {
          ram.setUint32(at & 0x7fffff, color);
        } else {
          ram.setUint16(at & 0x7fffff, (x + col).isEven ? color >>> 16 : color);
        }
      }
    }
  }
}

/// The value at pixel (x, y) is (dx*x + dy*y + origin) * 2^exponent.
class N64RdpPlane {
  const N64RdpPlane(this.dx, this.dy, this.origin, this.exponent);

  final int dx, dy, origin, exponent;
}

/// One snapshot of the decoded color combiner and its draw-local inputs.
class N64RdpCombiner {
  N64RdpCombiner(this.cycles, this.primitive, this.environment, this.shade,
      Int32List selectors, this.shadePlanes)
      : plan =
            Int32List.sublistView(Int32List.fromList(selectors), 0, cycles * 9);

  final int cycles, primitive, environment, shade;
  final Int32List plan;
  final List<N64RdpPlane>? shadePlanes;
}

class N64RdpTextureAxis {
  const N64RdpTextureAxis(
      this.low, this.scale, this.limit, this.mode, this.mask);

  final double low, scale;
  final int limit, mode, mask;

  int coordinate(double value) {
    var coord = (value * scale - low).floor();
    if ((mode & 2) != 0) coord = coord.clamp(0, limit);
    if (mask != 0) {
      final period = 1 << mask;
      final mirror = (mode & 1) != 0 && (coord & period) != 0;
      coord &= period - 1;
      if (mirror) coord = period - 1 - coord;
    }
    return coord;
  }
}

/// Coverage rules of the software rasterizer.
abstract final class N64RdpCoverage {
  @pragma('vm:prefer-inline')
  static bool covers(double wa, double wb, int px, int py, double x0, double y0,
      double x1, double y1, double x2, double y2, double invArea) {
    final wc = 1 - wa - wb;
    if (wa > 1e-10 && wb > 1e-10 && wc > 1e-10) return true;
    // Re-evaluate edge ties so stepping roundoff cannot open cracks.
    if (wa.abs() < 1e-10 || wb.abs() < 1e-10 || wc.abs() < 1e-10) {
      final x = px + 0.5, y = py + 0.5;
      final a = ((x - x1) * (y2 - y1) - (y - y1) * (x2 - x1)) * invArea;
      final b = ((x - x2) * (y0 - y2) - (y - y2) * (x0 - x2)) * invArea;
      return a >= 0 && b >= 0 && 1 - a - b >= 0;
    }
    return wa >= 0 && wb >= 0 && wc >= 0;
  }
}

typedef N64CopyPixel = int Function(
    Uint8List? tmem,
    int offset,
    bool odd,
    int format,
    int size,
    int palette,
    bool iaPalette,
    int at,
    int bytes,
    bool blend,
    N64RdpCombiner? combiner,
    int x,
    int y,
    Float64List? values,
    int shadeAt, [int? rgbaWord]);

class _DepthCheckpoint {
  _DepthCheckpoint(this.depth, this.epoch, this.rects, this.params,
      this.input, this.combiners, this.clear);

  final Float64List depth;
  final int epoch, clear;
  final List<N64RdpRect> rects;
  final Uint32List params, input;
  final List<N64RdpCombiner?> combiners;
}

/// Submits RDP draws together and applies their results in command order.
class N64RdpCompute {
  static const maxExtent = 1024;
  static const _maxDraws = n64RdpMaxDraws;
  static const _outputWords = maxExtent * maxExtent;
  static const _workgroupWords = 64;
  static const _paramWords = 16;
  static const _tileSide = 8;
  static const _tileHeader = 3;
  static const _tileWords = 3 + (_maxDraws + 31) ~/ 32;
  static const _tilePixels = _tileSide * _tileSide;
  static const _maxTiles = _outputWords ~/ _tilePixels;
  static const _jobOffset = _maxDraws * _paramWords;
  static const _tableWords = _jobOffset + _outputWords ~/ _workgroupWords;
  static const _tmemBytes = 4096;
  static const _tmemWords = _tmemBytes ~/ 4;
  // Keep the storage budget independent of the number of draw descriptors.
  // Batches with wide or tall draws can reach this limit first.
  static const _inputWords = n64RdpTileSeedOffset;
  static const _backgroundChunk = 4096;
  static const _maxBackgroundDispatches =
      (maxExtent * maxExtent + _backgroundChunk - 1) ~/ _backgroundChunk;
  static const _depthCapacity = n64RdpDepthCapacity;
  static const _packedColor = 1 << 15, _residentDepthFlag = 1 << 16;
  static const _cacheColorFlag = 1 << 29, _readCachedColorFlag = 1 << 30;

  N64RdpCompute(ComputeSink sink, this.bus, this.replayPixel)
      : _program = sink.program(
            n64RdpComputeShader,
            ['drawBatch', 'drawTiles', 'drawAliasedBackground'],
            const [
              ComputeBinding(
                  ComputeBindingKind.readOnlyStorage,
                  (_inputWords + 3 * _outputWords) * 4),
              ComputeBinding(
                  ComputeBindingKind.storage, _maxTiles * _tilePixels * 4 * 4),
              ComputeBinding(
                  ComputeBindingKind.readOnlyStorage, _tableWords * 4),
              ComputeBinding(ComputeBindingKind.readOnlyStorage,
                  (_tileHeader + _maxTiles * _tileWords) * 4),
              ComputeBinding(
                  ComputeBindingKind.storage, _depthCapacity * 12 + _outputWords * 4),
            ],
            paramStride: 0,
            maxDispatches: _maxBackgroundDispatches);

  final N64Bus bus;
  final N64CopyPixel replayPixel;
  final ComputeProgram _program;
  final _rects = <N64RdpRect>[];
  var _combiners = List<N64RdpCombiner?>.filled(_maxDraws, null);
  Uint32List _input = Uint32List(0);
  Int32List _signedInput = Int32List(0);
  Uint8List _inputBytes = Uint8List(0);
  Float32List _floatInput = Float32List(0);
  var _params = Uint32List(_tableWords);
  final _tiles = Uint32List(_tileHeader + _maxTiles * _tileWords);
  Int32List _tileSlots = Int32List(0);
  final _dispatch = Uint32List.fromList([0, 0, 1, 1]);
  static final _noParams = Uint32List(0);
  Uint32List _pixels = Uint32List(0);
  Uint32List _tileSeeds = Uint32List(0);
  Float64List? _depth;
  int _depthOutputWords = 0;
  bool _depthNeeded = false;
  Float64List? _residentDepth;
  _DepthCheckpoint? _depthCheckpoint;
  Uint32List _depthReadback = Uint32List(0);
  bool _deferredDepthOutput = false;
  int _residentDepthEpoch = 0;
  bool _allowResidentDepth = true;
  bool _recordingStream = false;
  N64RdpRect? _residentColorTarget;
  final _residentColorTiles = <int>{};

  void beginStream() => _recordingStream = true;

  void endStream() {
    _recordingStream = false;
    invalidateColor();
  }

  void invalidateColor() {
    _residentColorTarget = null;
    _residentColorTiles.clear();
  }

  void exposeDepth() {
    syncDepth();
    _allowResidentDepth = false;
    _residentDepth = null;
  }

  void invalidateDepth() {
    syncDepth();
    _residentDepth = null;
  }
  // Draw index plus one of the most recent clear. Zero means no clear.
  int _depthClear = 0;
  bool _depthClearedAtStart = false;
  int _inputUsed = 0, _outputUsed = 0;
  int _start = 0, _end = 0;
  int _pendingTiles = 0, _pendingWords = 0;
  Uint8List? _pendingColorTiles;
  final _committedColorTiles = <int>{};
  int _pendingColorCount = 0;
  int _projectedTmemVersion = -1, _projectedTmemBase = 0;
  bool enabled = true;
  bool _destinationNeeded = false, _orderedColor = false;
  bool _mixedTargets = false;

  bool overlaps(int at, int size) {
    if (at + size <= _start || at >= _end) return false;
    for (final rect in _rects) {
      if (rect.overlaps(at, size)) return true;
    }
    return false;
  }

  static bool _sameTarget(N64RdpRect a, N64RdpRect b) =>
      a.address == b.address &&
      a.stride == b.stride &&
      a.pixelBytes == b.pixelBytes;

  int _reserve(N64RdpRect rect, int mode, int rowWords,
      {bool blend = false,
      Float64List? depth,
      N64RdpCombiner? combiner,
      int extraInputWords = 0}) {
    if (_pendingWords != 0) flush();
    if ((_depth != null && depth != null && !identical(_depth, depth)) ||
        (_rects.isNotEmpty &&
            (_destinationNeeded ||
                blend ||
                _depth != null ||
                depth != null ||
                _orderedColor ||
                mode == 5 ||
                combiner != null) &&
            (_mixedTargets || !_sameTarget(_rects.first, rect)))) {
      flush();
    }
    // A workgroup writes words belonging to one rectangle.
    final words = rowWords * rect.height;
    final groups = (words + _workgroupWords - 1) ~/ _workgroupWords;
    final reserved = groups * _workgroupWords;
    if (_rects.length == _maxDraws || _outputUsed + reserved > _outputWords) {
      flush();
    }
    if (!enabled) return -1;
    // A standard draw reserves enough room for TMEM, offsets and registers.
    final needed = _inputUsed + _tmemWords + 2 * maxExtent + 40 + extraInputWords;
    if (needed > _inputWords) {
      flush();
      if (!enabled) return -1;
    }
    _growInput(_inputUsed + _tmemWords + 2 * maxExtent + 40 + extraInputWords);
    final draw = _rects.length;
    if (draw == 0) {
      _start = rect.start;
      _end = rect.end;
    } else {
      if (rect.start < _start) _start = rect.start;
      if (rect.end > _end) _end = rect.end;
      _mixedTargets |= !_sameTarget(_rects.first, rect);
    }
    _rects.add(rect);
    _orderedColor |= mode == 5;
    _combiners[draw] = combiner;
    _destinationNeeded |= blend;
    _depth ??= depth;
    final p = draw * _paramWords;
    _params[p] = rowWords;
    _params[p + 1] = rect.height;
    _params[p + 2] = rect.pixelBytes;
    _params[p + 3] = mode == 0 ? rect.x & 1 : _writeCombiner(combiner);
    _params[p + 8] = _outputUsed;
    _params[p + 11] = mode;
    _params[p + 12] = rect.x;
    _params[p + 13] = rect.y;
    _params[p + 14] = rect.width;
    _params[p + 15] = _depthClear << 3;
    final job = _jobOffset + _outputUsed ~/ _workgroupWords;
    _params.fillRange(job, job + groups, draw);
    _outputUsed += reserved;
    return p;
  }

  void _growInput(int needed) {
    if (needed <= _input.length) return;
    final capacity = math.min(
        _inputWords, math.max(needed, math.max(4096, _input.length * 2)));
    final input = Uint32List((capacity + 1) & ~1);
    input.setRange(0, _inputUsed, _input);
    _input = input;
    _signedInput = Int32List.view(input.buffer);
    _inputBytes = Uint8List.view(input.buffer);
    _floatInput = Float32List.view(input.buffer);
  }

  // Offset plus one leaves zero for the exact copy path.
  int _writeCombiner(N64RdpCombiner? combiner) {
    if (combiner == null) return 0;
    _orderedColor = true;
    final start = _inputUsed;
    final planes = combiner.shadePlanes;
    _input[_inputUsed++] = combiner.cycles;
    _input[_inputUsed++] = combiner.primitive;
    _input[_inputUsed++] = combiner.environment;
    _input[_inputUsed++] = combiner.shade;
    _input[_inputUsed++] = planes == null ? 0 : 1;
    if (planes != null) {
      for (final p in planes) {
        _signedInput[_inputUsed++] = p.dx;
        _signedInput[_inputUsed++] = p.dy;
        _signedInput[_inputUsed++] = p.origin;
        _signedInput[_inputUsed++] = p.exponent;
      }
    } else {
      _inputUsed += 16;
    }
    _input.setRange(
        _inputUsed, _inputUsed + combiner.plan.length, combiner.plan);
    _inputUsed += combiner.plan.length;
    return start + 1;
  }

  bool fill(N64RdpRect rect, int color) {
    final rowWords = (rect.width * rect.pixelBytes + 3) ~/ 4;
    final p = _reserve(rect, 0, rowWords);
    if (p < 0) return false;
    _params[p + 4] = color;
    return true;
  }

  bool solid(N64RdpRect rect, bool blend, N64RdpCombiner combiner) {
    final p = _reserve(rect, 6, rect.width, blend: blend, combiner: combiner);
    if (p < 0) return false;
    _params[p + 7] = blend ? 4 : 0;
    return true;
  }

  void clearDepth(Float64List depth) {
    if (_pendingWords != 0 ||
        (_depth != null && !identical(_depth, depth)) ||
        (_depth == null && _mixedTargets)) {
      flush();
    }
    _depth = depth;
    _depthClear = _rects.length + 1;
    _depthClearedAtStart |= _rects.isEmpty;
  }

  bool background(N64RdpRect rect, int source, int sourceWidth, int size,
      List<int> columns, List<int> rows, bool blend, N64RdpCombiner? combiner) {
    var minX = sourceWidth, maxX = 0;
    for (final x in columns) {
      minX = math.min(minX, x);
      maxX = math.max(maxX, x);
    }
    final bytes = size == 3 ? 4 : 2;
    final rowBytes = (maxX - minX + 1) * bytes;
    final rowOffsets = <int, int>{};
    var length = 0, needsFlush = false, aliasesDestination = false;
    for (final y in rows) {
      final address = source + (y * sourceWidth + minX) * bytes;
      if (rowOffsets.containsKey(address)) continue;
      if (address + rowBytes > bus.ram.length) return false;
      aliasesDestination |= rect.overlaps(address, rowBytes);
      needsFlush |= overlaps(address, rowBytes);
      rowOffsets[address] = length;
      length += rowBytes;
    }
    if (aliasesDestination) {
      return _drawAliasedBackground(rect, source + minX * bytes,
          sourceWidth * bytes, minX, rowBytes, rowOffsets.keys,
          size, columns, rows, blend, combiner);
    }
    if (needsFlush) flush();
    final words = (length + 3) ~/ 4;
    final p = _reserve(rect, 7, rect.width,
        blend: blend, combiner: combiner, extraInputWords: words);
    if (p < 0) return false;
    final base = _inputUsed;
    for (final row in rowOffsets.entries) {
      final at = base * 4 + row.value;
      _inputBytes.setRange(at, at + rowBytes, bus.ram, row.key);
    }
    _inputUsed += words;
    _params[p + 5] = size;
    _params[p + 7] = blend ? 4 : 0;
    _params[p + 9] = base;
    _params[p + 10] = _inputUsed;
    for (final x in columns) {
      _input[_inputUsed++] = (x - minX) * bytes;
    }
    for (final y in rows) {
      _input[_inputUsed++] = rowOffsets[source + (y * sourceWidth + minX) * bytes]!;
    }
    return true;
  }

  // Source and destination share one mutable byte range for raster-order
  // sampling. The guest sees the result only once the full draw succeeds.
  bool _drawAliasedBackground(N64RdpRect rect, int source, int pitch, int minX,
      int rowBytes, Iterable<int> sourceRows, int size, List<int> columns,
      List<int> rows, bool blend, N64RdpCombiner? combiner) {
    flush();
    invalidateColor();
    if (!enabled) return false;
    final ram = bus.ram;
    var start = rect.start, end = math.min(rect.end, ram.length);
    for (final address in sourceRows) {
      start = math.min(start, address);
      end = math.max(end, address + rowBytes);
    }
    final length = end - start;
    final words = 1 + (length + 3) ~/ 4;
    if (_pixels.length < words) _pixels = Uint32List(words);
    final pixels = Uint32List.sublistView(_pixels, 0, words);
    final snapshot = Uint8List.view(pixels.buffer, 4, length);
    pixels[0] = 0;
    snapshot.setRange(0, length, ram, start);

    _growInput(40 + columns.length + rows.length);
    final params = _params;
    try {
      params[0] = rect.stride * rect.pixelBytes;
      params[1] = rect.height;
      params[2] = rect.pixelBytes;
      params[3] = _writeCombiner(combiner);
      params[5] = size;
      params[7] = blend ? 4 : 0;
      params[8] = rect.start - start;
      params[9] = length;
      params[10] = _inputUsed;
      params[14] = rect.width;
      final texelBytes = size == 3 ? 4 : 2;
      for (final x in columns) {
        _input[_inputUsed++] = (x - minX) * texelBytes;
      }
      for (final y in rows) {
        _input[_inputUsed++] = source - start + y * pitch;
      }
      final count = rect.width * rect.height;
      final chunks = (count + _backgroundChunk - 1) ~/ _backgroundChunk;
      final commands = Uint32List(chunks * 4);
      for (var at = 0; at < commands.length; at += 4) {
        commands[at] = 2;
        commands[at + 1] = commands[at + 2] = commands[at + 3] = 1;
      }
      _program.write(0, 0, _input, 0, _inputUsed);
      _program.write(1, 0, pixels);
      _program.write(2, 0, params, 0, _paramWords);
      _program.run(commands, chunks, _noParams, wait: false);
      _program.read(1, 0, pixels);
      if (pixels[0] != count) return false;
      ram.setRange(start, end, snapshot);
      return true;
    } on Exception {
      enabled = false;
      return false;
    } finally {
      _inputUsed = 0;
      _orderedColor = false;
    }
  }

  int copy(N64RdpRect rect, Uint8List tmem, int format, int size, int palette,
      bool iaPalette, bool flip, bool blend, N64RdpCombiner? combiner) {
    final p = _reserve(rect, 1, rect.width, blend: blend, combiner: combiner);
    if (p < 0) return -1;
    final base = _inputUsed;
    final sLength = flip ? rect.height : rect.width;
    _inputBytes.setRange(base * 4, base * 4 + _tmemBytes, tmem);
    _params[p + 4] = format;
    _params[p + 5] = size;
    _params[p + 6] = palette;
    _params[p + 7] = (iaPalette ? 1 : 0) | (flip ? 2 : 0) | (blend ? 4 : 0);
    _params[p + 9] = base;
    _params[p + 10] = base + _tmemWords + sLength;
    _inputUsed += _tmemWords + rect.width + rect.height;
    return base + _tmemWords;
  }

  int _triangle(N64RdpRect rect, int mode, Int32List edges, N64RdpPlane? plane,
      Float64List? depth, bool depthTest, bool depthWrite,
      {bool blend = false, N64RdpCombiner? combiner}) {
    final p = _reserve(rect, mode, rect.width,
        depth: depth, blend: blend, combiner: combiner);
    if (p < 0) return -1;
    final base = _inputUsed;
    _signedInput.setRange(base, base + edges.length, edges);
    _params[p + 10] = base;
    _inputUsed += edges.length;
    if (plane != null) {
      _params[p + 15] |= (depthTest ? 1 : 0) | (depthWrite ? 2 : 0);
      _depthNeeded |= depthTest;
      if (depthWrite) _depthOutputWords = 2;
      _signedInput[_inputUsed++] = plane.dx;
      _signedInput[_inputUsed++] = plane.dy;
      _signedInput[_inputUsed++] = plane.origin;
      _signedInput[_inputUsed++] = plane.exponent;
    } else if (mode == 3) {
      _inputUsed += 4;
    }
    return p;
  }

  bool triangle(N64RdpRect rect, int color, Int32List edges,
      {N64RdpPlane? plane,
      Float64List? depth,
      bool depthTest = false,
      bool depthWrite = false}) {
    final p = _triangle(rect, 2, edges, plane, depth, depthTest, depthWrite);
    if (p < 0) return false;
    _params[p + 4] = color;
    _params[p + 7] = 0;
    return true;
  }

  bool shadedTriangle(
      N64RdpRect rect,
      Int32List edges,
      N64RdpPlane? plane,
      Float64List? depth,
      bool depthTest,
      bool depthWrite,
      bool blend,
      N64RdpCombiner combiner) {
    final p = _triangle(rect, 4, edges, plane, depth, depthTest, depthWrite,
        blend: blend, combiner: combiner);
    if (p < 0) return false;
    _params[p + 7] = blend ? 4 : 0;
    return true;
  }

  bool texturedTriangle(
      N64RdpRect rect,
      Int32List edges,
      N64RdpPlane? plane,
      Float64List? depth,
      bool depthTest,
      bool depthWrite,
      Uint8List tmem,
      int format,
      int size,
      int palette,
      bool iaPalette,
      bool blend,
      Int32List texture,
      N64RdpCombiner? combiner) {
    final p = _triangle(rect, 3, edges, plane, depth, depthTest, depthWrite,
        blend: blend, combiner: combiner);
    if (p < 0) return false;
    // After the three edges and optional depth plane, write the two
    // texture axes, TMEM layout, reciprocal plane, and packed TMEM.
    _signedInput.setRange(_inputUsed, _inputUsed + texture.length, texture);
    _inputUsed += texture.length;
    _inputBytes.setRange(_inputUsed * 4, _inputUsed * 4 + _tmemBytes, tmem);
    _params[p + 4] = format;
    _params[p + 5] = size;
    _params[p + 6] = palette;
    _params[p + 7] = (iaPalette ? 1 : 0) | (blend ? 4 : 0);
    _params[p + 9] = _inputUsed;
    _inputUsed += _tmemWords;
    return true;
  }

  bool projectedTriangle(
      N64RdpRect rect, Uint8List? tmem, int tmemVersion, int format, int size,
      int palette, bool iaPalette, bool blend, bool depthTest, bool depthWrite,
      bool decal, Float64List? depth, N64RdpCombiner? combiner, Float32List vertices,
      N64RdpTextureAxis? sAxis, N64RdpTextureAxis? tAxis, int tmemOffset, int pitch) {
    final p = _reserve(rect, 5, rect.width,
        depth: depth, blend: blend, combiner: combiner, extraInputWords: 40);
    if (p < 0) return false;
    if (tmem != null) {
      if (_projectedTmemVersion != tmemVersion) {
        _projectedTmemVersion = tmemVersion;
        _projectedTmemBase = _inputUsed;
        _inputBytes.setRange(_inputUsed * 4, _inputUsed * 4 + _tmemBytes, tmem);
        _inputUsed += _tmemWords;
      }
      _params[p + 9] = _projectedTmemBase;
    }
    _params[p + 4] = format;
    _params[p + 5] = size;
    _params[p + 6] = palette;
    _params[p + 7] =
        (iaPalette ? 1 : 0) | (blend ? 4 : 0) | (tmem == null ? 8 : 0);
    _params[p + 15] |= (depthTest ? 1 : 0) | (depthWrite ? 2 : 0) | (decal ? 4 : 0);
    _depthNeeded |= depthTest;
    if (depthWrite && _depthOutputWords == 0) _depthOutputWords = 1;
    final base = _inputUsed;
    _params[p + 10] = base;
    _floatInput.setRange(base, base + 30, vertices);
    if (sAxis != null && tAxis != null) {
      _floatInput[base + 30] = sAxis.low;
      _floatInput[base + 31] = tAxis.low;
      _floatInput[base + 32] = sAxis.scale;
      _floatInput[base + 33] = tAxis.scale;
      _input[base + 34] = sAxis.limit;
      _input[base + 35] = tAxis.limit;
      _input[base + 36] = sAxis.mode | (sAxis.mask << 2);
      _input[base + 37] = tAxis.mode | (tAxis.mask << 2);
      _input[base + 38] = tmemOffset;
      _input[base + 39] = pitch;
    }
    _inputUsed += 40;
    return true;
  }

  void setTextureS(int index, int offset, bool odd) {
    _input[index] = (offset & 4095) | (odd ? 4096 : 0);
  }

  void setTextureT(int index, int offset) {
    _input[index] = offset & 4095;
  }

  // Draws on the same pixel grid can resolve into one color per pixel.
  // Targets that alias with a different stride or format stay in command order.
  int _binTiles() {
    if (_mixedTargets) return 0;
    if (_rects.length < 2 &&
        !_destinationNeeded &&
        _depth == null &&
        !_orderedColor) {
      return 0;
    }
    final first = _rects.first;
    var minX = first.x, minY = first.y, maxX = minX, maxY = minY;
    for (final rect in _rects) {
      if (rect.x < 0 ||
          rect.y < 0 ||
          rect.x + rect.width > rect.stride) {
        return 0;
      }
      minX = math.min(minX, rect.x);
      minY = math.min(minY, rect.y);
      maxX = math.max(maxX, rect.x + rect.width - 1);
      maxY = math.max(maxY, rect.y + rect.height - 1);
    }

    final tileX = minX ~/ _tileSide, tileY = minY ~/ _tileSide;
    final cols = maxX ~/ _tileSide - tileX + 1;
    final rows = maxY ~/ _tileSide - tileY + 1;
    final slots = cols * rows;
    if (slots > 4 * _maxTiles) return 0;
    if (_tileSlots.length < slots) _tileSlots = Int32List(slots);
    _tileSlots.fillRange(0, slots, -1);
    var count = 0;
    for (var draw = 0; draw < _rects.length; draw++) {
      final rect = _rects[draw];
      final x0 = rect.x ~/ _tileSide,
          x1 = (rect.x + rect.width - 1) ~/ _tileSide;
      final y0 = rect.y ~/ _tileSide,
          y1 = (rect.y + rect.height - 1) ~/ _tileSide;
      final group = draw ~/ 32, flag = 1 << (draw % 32);
      for (var y = y0; y <= y1; y++) {
        for (var x = x0; x <= x1; x++) {
          final i = (y - tileY) * cols + x - tileX;
          var slot = _tileSlots[i];
          if (slot < 0) {
            if (count == _maxTiles) return 0;
            slot = _tileHeader + count++ * _tileWords;
            _tileSlots[i] = slot;
            _tiles[slot] = x * _tileSide;
            _tiles[slot + 1] = y * _tileSide;
            _tiles.fillRange(slot + 2, slot + _tileWords, 0);
          }
          _tiles[slot + 2] |= 1 << group;
          _tiles[slot + 3 + group] |= flag;
        }
      }
    }
    return count;
  }

  void flush({bool defer = false, bool endStream = false}) {
    final count = _rects.length;
    if (count == 0) {
      if (_depthClear != 0) {
        if (identical(_depthCheckpoint?.depth, _depth)) _depthCheckpoint = null;
        if (identical(_residentDepth, _depth)) _residentDepth = null;
        _clearDepth();
        _depth = null;
        _depthClear = 0;
        _depthClearedAtStart = false;
      }
      return;
    }
    final pending = _pendingWords != 0;
    if (pending && defer) return;
    final tileCount = pending ? _pendingTiles : _binTiles();
    final useGpu = tileCount != 0 ||
        (!_destinationNeeded && _depth == null && !_orderedColor);
    final colorWords = _rects.first.pixelBytes == 2 ? 1 : 2;
    if (!pending) {
      final depth = _depth;
      final clearsPlane = depth != null && _depthClearedAtStart;
      final checkpoint = _depthCheckpoint;
      if (checkpoint != null && depth != null) {
        if (clearsPlane && identical(depth, checkpoint.depth)) {
          _depthCheckpoint = null;
        } else {
          syncDepth();
        }
      }
      _deferredDepthOutput = defer && tileCount != 0 && clearsPlane &&
          _allowResidentDepth && depth != null && depth.length <= _depthCapacity &&
          _rects.first.stride < 4096 && _residentDepthEpoch < 0xffffffff &&
          _depthOutputWords != 0;
    }
    final pixelWords = colorWords + (_deferredDepthOutput ? 0 : _depthOutputWords);
    final words = pending ? _pendingWords :
        tileCount == 0 ? _outputUsed : tileCount * _tilePixels * pixelWords;
    if (_pixels.length < words) _pixels = Uint32List(words);
    final pixels = Uint32List.sublistView(_pixels, 0, words);
    try {
      if (pending) {
        _pendingWords = 0;
        bus.unwatchRdram();
      }
      if (useGpu && enabled) {
        if (!pending) {
          _runBatch(count, tileCount, endStream);
          if (defer && words != 0) {
            if (_deferredDepthOutput) {
              _pendingColorTiles = Uint8List(tileCount);
              _pendingColorCount = tileCount;
            } else {
              _program.prefetch(1, 0, words * 4);
            }
            bus.watchRdram(_start, math.min(_end, bus.ram.length), flush,
                settleRange: _deferredDepthOutput ? _readRdramRange : null);
            _pendingTiles = tileCount;
            _pendingWords = words;
            return;
          }
        }
        if (_pendingColorTiles != null) {
          if (_pendingColorCount != 0) _readColorTiles(0, tileCount);
        } else {
          _program.read(1, 0, pixels);
        }
      }
    } on Exception {
      // No output has reached RDRAM yet. Replay the entire batch in order.
      enabled = false;
    }
    try {
      if (enabled && useGpu && tileCount != 0) {
        if (_deferredDepthOutput) {
          _depthCheckpoint = _DepthCheckpoint(_depth!, _residentDepthEpoch,
              List.of(_rects), Uint32List.fromList(Uint32List.sublistView(
                  _params, 0, count * _paramWords)),
              Uint32List.fromList(Uint32List.sublistView(_input, 0, _inputUsed)),
              _combiners.sublist(0, count), _depthClear);
        } else if (_depthClear != 0) {
          _clearDepth();
        }
        if (_pendingColorTiles == null) {
          _storeTiles(pixels, tileCount, _rects.first, pixelWords,
              _deferredDepthOutput ? 0 : _depthOutputWords);
        }
        return;
      }
      if (_depth != null) invalidateDepth();
      invalidateColor();
      final bytes = Uint8List.view(pixels.buffer);
      var clear = 0;
      for (var i = 0; i < count; i++) {
        final rect = _rects[i], p = i * _paramWords;
        final mode = _params[p + 11];
        final nextClear = _params[p + 15] >> 3;
        if (clear != nextClear) {
          _clearDepth();
          clear = nextClear;
        }
        if (enabled && useGpu) {
          if (mode == 0) {
            _storeFill(rect, bytes, _params[p + 8] * 4, _params[p] * 4);
          } else {
            _storeMasked(rect, pixels, _params[p + 8]);
          }
        } else if (mode == 0) {
          rect.writeFill(bus, _params[p + 4], colorCommitted:
              _committedColorTiles.isEmpty ? null : _colorCommitted);
        } else if (mode == 5) {
          _replayProjected(rect, p);
        } else if (mode >= 2 && mode <= 4) {
          _replayTriangle(rect, p, mode);
        } else {
          _replayRect(rect, p);
        }
      }
      if (clear != _depthClear) _clearDepth();
    } finally {
      _rects.clear();
      _projectedTmemVersion = -1;
      _combiners.fillRange(0, count, null);
      _start = _end = _inputUsed = _outputUsed = 0;
      _destinationNeeded = _orderedColor = _mixedTargets = false;
      _depth = null;
      _depthOutputWords = 0;
      _deferredDepthOutput = false;
      _depthNeeded = false;
      _depthClear = 0;
      _depthClearedAtStart = false;
      _pendingColorTiles = null;
      _committedColorTiles.clear();
      _pendingColorCount = 0;
    }
  }

  static int _colorTileKey(int x, int y) => (y >> 3) * 1024 + (x >> 3);

  bool _colorCommitted(int x, int y) =>
      _committedColorTiles.contains(_colorTileKey(x, y));

  void _readRdramRange(int start, int size) {
    final done = _pendingColorTiles!;
    final target = _rects.first;
    final end = start + size, pitch = target.stride * target.pixelBytes;
    var first = done.length, last = 0;
    for (var i = 0; i < done.length; i++) {
      if (done[i] != 0) continue;
      final slot = _tileHeader + i * _tileWords;
      final x = _tiles[slot], y = _tiles[slot + 1];
      final rowBytes = math.min(_tileSide, target.stride - x) * target.pixelBytes;
      final address = target.address + y * pitch + x * target.pixelBytes;
      if (address >= end || address + 7 * pitch + rowBytes <= start) continue;
      for (var row = address, r = 0; r < _tileSide; r++, row += pitch) {
        if (row >= end) break;
        if (row + rowBytes <= start) continue;
        if (i < first) first = i;
        last = i + 1;
        break;
      }
    }
    if (last <= first) return;
    try {
      _readColorTiles(first, last);
    } on Exception {
      enabled = false;
      flush();
      return;
    }
    if (_pendingColorCount == 0) flush();
  }

  void _readColorTiles(int first, int last) {
    final target = _rects.first, done = _pendingColorTiles!;
    final words = _tilePixels * (target.pixelBytes == 2 ? 1 : 2);
    while (first < last && done[first] != 0) first++;
    while (last > first && done[last - 1] != 0) last--;
    if (first >= last) return;
    final pixels = Uint32List.sublistView(_pixels, 0, (last - first) * words);
    _program.read(1, first * words * 4, pixels);
    _storeTiles(pixels, last - first, target, words ~/ _tilePixels, 0,
        firstTile: first, committed: done);
  }

  void syncDepth() {
    final checkpoint = _depthCheckpoint;
    if (checkpoint == null) return;
    _depthCheckpoint = null;
    var first = checkpoint.depth.length, last = 0;
    for (var i = 0; i < checkpoint.rects.length; i++) {
      if ((checkpoint.params[i * _paramWords + 15] & 2) == 0) continue;
      final r = checkpoint.rects[i];
      final start = r.y * r.stride + r.x;
      first = math.min(first, start);
      last = math.max(last, start + (r.height - 1) * r.stride + r.width);
    }
    final words = (last - first) * 3;
    if (_depthReadback.length < words) _depthReadback = Uint32List(words);
    try {
      _program.read(4, first * 12, Uint32List.sublistView(_depthReadback, 0, words));
      checkpoint.depth.fillRange(0, checkpoint.depth.length, double.infinity);
      final depth = Uint32List.sublistView(checkpoint.depth);
      for (var i = first * 2, at = 0; at < words; i += 2, at += 3) {
        if (_depthReadback[at + 2] != checkpoint.epoch) continue;
        depth[i] = _depthReadback[at];
        depth[i + 1] = _depthReadback[at + 1];
      }
    } on Exception {
      _restoreDepth(checkpoint);
      enabled = false;
    }
  }

  void _restoreDepth(_DepthCheckpoint checkpoint) {
    final params = _params, input = _input, combiners = _combiners, depth = _depth;
    final signed = _signedInput, floats = _floatInput, bytes = _inputBytes;
    try {
      _params = checkpoint.params;
      _input = checkpoint.input;
      _combiners = checkpoint.combiners;
      _depth = checkpoint.depth;
      _signedInput = Int32List.view(_input.buffer);
      _floatInput = Float32List.view(_input.buffer);
      _inputBytes = Uint8List.view(_input.buffer);
      var clear = 0;
      for (var i = 0; i < checkpoint.rects.length; i++) {
        final p = i * _paramWords;
        final flags = _params[p + 15];
        if (flags >> 3 != clear) {
          _clearDepth();
          clear = flags >> 3;
        }
        if ((flags & 2) == 0) continue;
        final mode = _params[p + 11], rect = checkpoint.rects[i];
        if (mode == 5) {
          _replayProjected(rect, p, depthOnly: true);
        } else {
          _replayTriangle(rect, p, mode, depthOnly: true);
        }
      }
      if (clear != checkpoint.clear) _clearDepth();
    } finally {
      _params = params;
      _input = input;
      _combiners = combiners;
      _depth = depth;
      _signedInput = signed;
      _floatInput = floats;
      _inputBytes = bytes;
    }
  }

  void _clearDepth() {
    final depth = _depth!;
    depth.fillRange(0, depth.length, double.infinity);
  }

  void _runBatch(int count, int tileCount, bool endStream) {
    if (_inputUsed != 0) _program.write(0, 0, _input, 0, _inputUsed);
    if (tileCount == 0) {
      invalidateColor();
      final groups = _outputUsed ~/ _workgroupWords;
      _program.write(2, 0, _params, 0, _jobOffset + groups);
      _dispatch[0] = 0;
      _dispatch[1] = groups;
    } else {
      final depth = _depth;
      final target = _rects.first;
      // Depth words tagged by an earlier clear read as infinity.
      final newDepthEpoch = _depthClearedAtStart && _residentDepthEpoch < 0xffffffff;
      final resident = _allowResidentDepth && depth != null &&
          depth.length <= _depthCapacity &&
          target.stride < 4096 &&
          (_depthClearedAtStart ? newDepthEpoch : identical(depth, _residentDepth));
      if (resident) {
        if (newDepthEpoch) _residentDepthEpoch++;
        // A clear in the middle of a batch invalidates depth outside its
        // tiles. The host plane is still synchronized by the readback.
        _residentDepth = _depthClear == 0 || newDepthEpoch ? depth : null;
      } else if (identical(depth, _residentDepth)) {
        _residentDepth = null;
      }
      final previousColor = _residentColorTarget;
      if (previousColor != null && !_sameTarget(previousColor, target)) {
        invalidateColor();
      }
      final carryColor = _recordingStream && !endStream &&
          target.stride < 4096 &&
          _end - target.address <= _outputWords * target.pixelBytes;
      if (!carryColor && !endStream) invalidateColor();
      var readCachedColor = _destinationNeeded && _residentColorTiles.isNotEmpty;
      if (readCachedColor) {
        for (var i = 0; i < tileCount; i++) {
          final base = _tileHeader + i * _tileWords;
          if (!_residentColorTiles.contains(_tiles[base + 1] * target.stride +
              _tiles[base])) {
            readCachedColor = false;
            break;
          }
        }
      }
      if (carryColor && _destinationNeeded) {
        _residentColorTarget = target;
        for (var i = 0; i < tileCount; i++) {
          final base = _tileHeader + i * _tileWords;
          _residentColorTiles.add(_tiles[base + 1] * target.stride + _tiles[base]);
        }
      }
      final cacheColor = carryColor && _residentColorTiles.isNotEmpty;
      _program.write(2, 0, _params, 0, count * _paramWords);
      _tiles[0] = (_destinationNeeded ? 1 : 0) |
          (_depth != null ? 2 : 0) |
          (_orderedColor ? 4 : 0) |
          (_depthClearedAtStart ? 8 : 0) |
          (_depthClear << 4) |
          (target.pixelBytes == 2 ? _packedColor : 0) |
          (resident ? _residentDepthFlag : 0) |
          (cacheColor ? _cacheColorFlag : 0) |
          (readCachedColor ? _readCachedColorFlag : 0) |
          (resident || cacheColor || readCachedColor ? target.stride << 17 : 0);
      _tiles[1] = _residentDepthEpoch;
      final loadDepth = _depthNeeded && depth != null && !_depthClearedAtStart && !resident;
      final loadColor = _destinationNeeded && !readCachedColor;
      final packedSeedColor = loadColor && !loadDepth && target.pixelBytes == 2;
      _tiles[2] = (loadColor ? 1 : 0) | (loadDepth ? 2 : 0) |
          (_deferredDepthOutput ? 0 : _depthOutputWords << 2) |
          (packedSeedColor ? 16 : 0);
      _program.write(3, 0, _tiles, 0, _tileHeader + tileCount * _tileWords);
      if (loadColor || loadDepth) {
        final seedWords = (loadColor ? 1 : 0) + (loadDepth ? 2 : 0);
        final words = tileCount * _tilePixels * seedWords ~/ (packedSeedColor ? 2 : 1);
        if (_tileSeeds.length < words) _tileSeeds = Uint32List(words);
        if (packedSeedColor) {
          _loadPackedColorTiles(tileCount, target);
        } else {
          _loadTiles(tileCount, target, seedWords, loadDepth, loadColor);
        }
        _program.write(0, _inputWords * 4, _tileSeeds, 0, words);
      }
      _dispatch[0] = 1;
      _dispatch[1] = tileCount;
    }
    _program.run(_dispatch, 1, _noParams, wait: false);
  }

  void _loadPackedColorTiles(int count, N64RdpRect target) {
    final bytes = Uint8List.view(_tileSeeds.buffer);
    final ram = bus.ram;
    for (var i = 0, dst = 0; i < count; i++) {
      final slot = _tileHeader + i * _tileWords;
      final x = _tiles[slot], y = _tiles[slot + 1];
      final rowBytes = math.min(_tileSide, target.stride - x) * 2;
      var src = target.address + (y * target.stride + x) * 2;
      for (var dy = 0; dy < _tileSide; dy++, dst += _tileSide * 2,
          src += target.stride * 2) {
        final length = math.min(rowBytes, ram.length - src) & ~1;
        if (length > 0) bytes.setRange(dst, dst + length, ram, src);
      }
    }
  }

  void _loadTiles(
      int count, N64RdpRect target, int seedWords, bool loadDepth, bool loadColor) {
    final ram = bus.ramData, limit = bus.ram.length;
    final stride = target.stride, size = target.pixelBytes;
    final depth = _depth;
    final depthWords = loadDepth ? Uint32List.sublistView(depth!) : null;
    final depthOffset = loadColor ? 1 : 0;
    final seeds = _tileSeeds;
    for (var i = 0, dst = 0; i < count; i++) {
      final slot = _tileHeader + i * _tileWords;
      final x = _tiles[slot], y = _tiles[slot + 1];
      var pixel = y * stride + x;
      for (var dy = 0; dy < _tileSide; dy++, pixel += stride) {
        var at = target.address + pixel * size;
        for (var dx = 0; dx < _tileSide; dx++, dst += seedWords, at += size) {
          if (x + dx >= stride) continue;
          if (loadColor && at + size <= limit) {
            seeds[dst] = size == 4 ? ram.getUint32(at) : ram.getUint16(at);
          }
          final index = pixel + dx;
          if (depthWords != null && index < depth!.length) {
            seeds[dst + depthOffset] = depthWords[index * 2];
            seeds[dst + depthOffset + 1] = depthWords[index * 2 + 1];
          }
        }
      }
    }
  }

  void _storeTiles(
      Uint32List pixels, int count, N64RdpRect target, int pixelWords, int outputDepth,
      {int firstTile = 0, Uint8List? committed}) {
    final ram = bus.ramData, limit = bus.ram.length;
    final stride = target.stride, size = target.pixelBytes;
    final colorWords = size == 2 ? 1 : 2;
    final depth = _depth;
    final compact = outputDepth == 1 ? Float32List.sublistView(pixels) : null;
    final depthWords = outputDepth == 2 ? Uint32List.sublistView(depth!) : null;
    for (var i = firstTile, src = 0; i < firstTile + count; i++) {
      if (committed != null && committed[i] != 0) {
        src += _tilePixels * pixelWords;
        continue;
      }
      final slot = _tileHeader + i * _tileWords;
      final x = _tiles[slot], y = _tiles[slot + 1];
      var row = target.address + (y * stride + x) * size;
      for (var dy = 0; dy < _tileSide; dy++, row += stride * size) {
        var at = row;
        for (var dx = 0; dx < _tileSide; dx++, src += pixelWords, at += size) {
          final mask = size == 2 ? pixels[src] >>> 16 : pixels[src + 1];
          final index = (y + dy) * stride + x + dx;
          if (outputDepth != 0 && (mask & 2) != 0) {
            if (compact != null) {
              depth![index] = compact[src + colorWords];
            } else {
              depthWords![index * 2] = pixels[src + colorWords];
              depthWords[index * 2 + 1] = pixels[src + colorWords + 1];
            }
          }
          if ((mask & 1) == 0 || at + size > limit) continue;
          if (size == 4) {
            ram.setUint32(at, pixels[src]);
          } else {
            ram.setUint16(at, pixels[src]);
          }
        }
      }
      if (committed != null) {
        committed[i] = 1;
        _pendingColorCount--;
        _committedColorTiles.add(_colorTileKey(x, y));
      }
    }
  }

  void _storeFill(N64RdpRect rect, Uint8List bytes, int src, int pitch) {
    final ram = bus.ram, pixelBytes = rect.pixelBytes;
    final width = rect.width * pixelBytes, stride = rect.stride * pixelBytes;
    var dst = rect.start;
    for (var y = 0; y < rect.height; y++, src += pitch, dst += stride) {
      final remaining = ram.length - dst;
      if (remaining <= 0) break;
      final length =
          remaining < width ? remaining ~/ pixelBytes * pixelBytes : width;
      ram.setRange(dst, dst + length, bytes, src);
    }
  }

  void _storeMasked(N64RdpRect rect, Uint32List pixels, int src) {
    final ram = bus.ramData, limit = bus.ram.length;
    final size = rect.pixelBytes, stride = rect.stride * size;
    var start = rect.start;
    for (var y = 0; y < rect.height; y++, start += stride) {
      var at = start;
      for (var x = 0; x < rect.width; x++, at += size) {
        final pixel = pixels[src++];
        if (at + size > limit || pixel == 0) continue;
        if (size == 4) {
          ram.setUint32(at, pixel);
        } else {
          ram.setUint16(at, pixel);
        }
      }
    }
  }

  int _textureCoord(int base, int x, int y, int reciprocal) {
    final q = _signedInput;
    final value = q[base] * x + q[base + 1] * y + q[base + 2];
    final shift = q[base + 3];
    final n = shift >= 0 ? value << shift : value;
    final d = shift >= 0 ? reciprocal : reciprocal << -shift;
    final fixed = n ~/ d - (n < 0 && n.remainder(d) != 0 ? 1 : 0);
    var coord = (fixed - q[base + 4]) >> 2;
    final flags = q[base + 6], mask = flags >> 2;
    if ((flags & 2) != 0) coord = coord.clamp(0, q[base + 5]);
    if (mask != 0) {
      final period = 1 << mask;
      final mirror = (flags & 1) != 0 && (coord & period) != 0;
      coord &= period - 1;
      if (mirror) coord = period - 1 - coord;
    }
    return coord;
  }

  void _replayRect(N64RdpRect rect, int p) {
    final base = _params[p + 9], flags = _params[p + 7];
    final mode = _params[p + 11];
    final memory = mode != 1 ? null :
        Uint8List.sublistView(_inputBytes, base * 4, (base + _tmemWords) * 4);
    final image = mode != 7 ? null : ByteData.sublistView(
        _inputBytes, base * 4, _params[p + 10] * 4);
    final sBase = image == null ? base + _tmemWords : _params[p + 10];
    final tBase = image == null ? _params[p + 10] : sBase + rect.width;
    final texelSize = _params[p + 5];
    final swapAxes = (flags & 2) != 0;
    final bytes = rect.pixelBytes, limit = bus.ram.length;
    final combiner = _combiners[p ~/ _paramWords];
    for (var y = 0; y < rect.height; y++) {
      var at = rect.start + y * rect.stride * bytes;
      for (var x = 0; x < rect.width; x++, at += bytes) {
        if (at + bytes > limit) break;
        if (_colorCommitted(rect.x + x, rect.y + y)) continue;
        final textured = memory != null || image != null;
        final s = textured ? _input[sBase + (swapAxes ? y : x)] : 0;
        final t = textured ? _input[tBase + (swapAxes ? x : y)] : 0;
        final rgba = image == null ? null :
            texelSize == 3 ? image.getUint32(s + t) : image.getUint16(s + t);
        final color = replayPixel(
            memory,
            ((s & 4095) + t) & 4095,
            (s & 4096) != 0,
            _params[p + 4],
            texelSize,
            _params[p + 6],
            (flags & 1) != 0,
            at,
            bytes,
            (flags & 4) != 0,
            combiner,
            x,
            y,
            null,
            0,
            rgba);
        if (color != 0) bus.ramWrite(at, color, bytes);
      }
    }
  }

  void _replayProjected(N64RdpRect rect, int p, {bool depthOnly = false}) {
    final flags = _params[p + 7], depthFlags = _params[p + 15] & 7;
    final texStart = _params[p + 9] * 4;
    final tmem = (flags & 8) == 0
        ? Uint8List.sublistView(_inputBytes, texStart, texStart + _tmemBytes)
        : null;
    final combiner = _combiners[p ~/ _paramWords];
    final base = _params[p + 10], values = _floatInput;
    final ax = values[base], ay = values[base + 1];
    final bx = values[base + 10], by = values[base + 11];
    final cx = values[base + 20], cy = values[base + 21];
    double edge(double x, double y, double ux, double uy, double vx, double vy) =>
        (x - ux) * (vy - uy) - (y - uy) * (vx - ux);
    final area = edge(cx, cy, ax, ay, bx, by);
    if (area == 0) return;
    final za = values[base + 2] - values[base + 22];
    final zb = values[base + 12] - values[base + 22];
    final tolerance = 1 +
        ((za * (cy - by) + zb * (ay - cy)) / area).abs() +
        ((za * (bx - cx) + zb * (cx - ax)) / area).abs();
    final sFlags = _input[base + 36], tFlags = _input[base + 37];
    final sAxis = N64RdpTextureAxis(values[base + 30], values[base + 32],
        _input[base + 34], sFlags & 3, sFlags >> 2);
    final tAxis = N64RdpTextureAxis(values[base + 31], values[base + 33],
        _input[base + 35], tFlags & 3, tFlags >> 2);
    final size = _params[p + 5], bytes = rect.pixelBytes;
    final rgba = Float64List(4);
    for (var y = 0; y < rect.height; y++) {
      var index = (rect.y + y) * rect.stride + rect.x;
      var at = rect.address + index * bytes;
      for (var x = 0; x < rect.width; x++, index++, at += bytes) {
        final keepColor = depthOnly || _colorCommitted(rect.x + x, rect.y + y);
        final px = x + 0.5, py = y + 0.5;
        final wa = edge(px, py, bx, by, cx, cy) / area;
        final wb = edge(px, py, cx, cy, ax, ay) / area;
        if (wa < 0 || wb < 0 || edge(px, py, ax, ay, bx, by) / area < 0) continue;
        double interpolate(int channel) {
          final c = values[base + 20 + channel];
          return c + wa * (values[base + channel] - c) +
              wb * (values[base + 10 + channel] - c);
        }
        final z = interpolate(2);
        if ((depthFlags & 1) != 0) {
          final old = _depth![index];
          if ((depthFlags & 4) != 0 ? (z - old).abs() > tolerance : z > old) {
            continue;
          }
        }
        var offset = 0, odd = false;
        if (tmem != null) {
          final q = interpolate(3);
          if (q == 0) continue;
          final tx = sAxis.coordinate(interpolate(4) / q);
          final ty = tAxis.coordinate(interpolate(5) / q);
          offset = (_input[base + 38] + ty * _input[base + 39] +
              tx * (4 << size) ~/ 8) & 4095;
          odd = tx.isOdd;
        }
        for (var channel = 0; channel < 4; channel++) {
          rgba[channel] = interpolate(6 + channel);
        }
        final color = replayPixel(tmem, offset, odd, _params[p + 4], size,
            _params[p + 6], (flags & 1) != 0, at, bytes, !keepColor && (flags & 4) != 0,
            combiner, x, y, rgba, 0);
        if (color == 0) continue;
        if (!keepColor) bus.ramWrite(at, color, bytes);
        if ((depthFlags & 2) != 0) _depth![index] = z;
      }
    }
  }

  void _replayTriangle(N64RdpRect rect, int p, int mode, {bool depthOnly = false}) {
    final size = rect.pixelBytes;
    final ram = bus.ramData, limit = bus.ram.length;
    final edge = _signedInput;
    final base = _params[p + 10], depthFlags = _params[p + 15] & 7;
    final scale =
        depthFlags == 0 ? 0.0 : math.pow(2, edge[base + 12]).toDouble();
    final depth = _depth;
    final tmemStart = _params[p + 9] * 4;
    final tmem = mode == 3
        ? Uint8List.sublistView(_inputBytes, tmemStart, tmemStart + _tmemBytes)
        : null;
    final format = _params[p + 4], texSize = _params[p + 5];
    final palette = _params[p + 6], flags = _params[p + 7];
    final combiner = _combiners[p ~/ _paramWords];
    for (var y = 0; y < rect.height; y++) {
      var at = rect.start + y * rect.stride * size;
      final a = edge[base + 1] * y + edge[base + 2],
          b = edge[base + 4] * y + edge[base + 5],
          c = edge[base + 7] * y + edge[base + 8];
      for (var x = 0; x < rect.width; x++, at += size) {
        if (at + size > limit) break;
        final keepColor = depthOnly || _colorCommitted(rect.x + x, rect.y + y);
        if (edge[base] * x + a < 0 ||
            edge[base + 3] * x + b < 0 ||
            edge[base + 6] * x + c < 0) {
          continue;
        }
        final index = (rect.y + y) * rect.stride + rect.x + x;
        final z = depthFlags == 0
            ? 0.0
            : (edge[base + 9] * x + edge[base + 10] * y + edge[base + 11]) *
                scale;
        if ((depthFlags & 1) != 0 && z > depth![index]) continue;
        var color = format;
        if (tmem != null) {
          final q = edge[base + 29] * x + edge[base + 30] * y + edge[base + 31];
          final s = _textureCoord(base + 13, x, y, q);
          final t = _textureCoord(base + 20, x, y, q);
          final offset = (edge[base + 27] +
                  t * edge[base + 28] +
                  s * (4 << texSize) ~/ 8) &
              4095;
          color = replayPixel(
              tmem,
              offset,
              s.isOdd,
              format,
              texSize,
              palette,
              (flags & 1) != 0,
              at,
              size,
              !keepColor && (flags & 4) != 0,
              combiner,
              x,
              y,
              null,
              0);
          if (color == 0) continue;
        } else if (mode == 4) {
          color = replayPixel(null, 0, false, 0, 0, 0, false, at, size,
              !keepColor && (flags & 4) != 0, combiner, x, y, null, 0);
          if (color == 0) continue;
        }
        if ((depthFlags & 2) != 0) depth![index] = z;
        if (keepColor) continue;
        if (size == 4) {
          ram.setUint32(at, color);
        } else {
          ram.setUint16(at, color);
        }
      }
    }
  }

  void dispose() => _program.dispose();
}
