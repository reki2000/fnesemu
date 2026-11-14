// Renders of the CORE on a compute program. The renderer walks the lists of
// a render on the CPU into a [DcComputeFrame] (gpu_render_record.dart), and
// the program of dc_compute_shader.dart shades every pixel of each tile from
// it, one thread per pixel, as DcGpuRender shades it. The renderer then
// writes the tiles to VRAM at the times it writes them without a program,
// so that the strip buffer and the vertical scaler stay on the CPU.
import 'dart:math' as math;
import 'dart:typed_data';

import '../../compute_sink.dart';
import 'dc_compute_shader.dart';
import 'fault.dart';
import 'gpu_fog.dart';
import 'gpu_modifier.dart';
import 'gpu_palette.dart';
import 'gpu_texture.dart';
import 'vram_pages.dart';

const recordWords = 48;
const modifierWords = 16;
const entryWords = 16;
const textureWords = 16;
const maxRecords = 1 << 18;
const maxModifiers = 1 << 16;
const maxEntries = 8192;
const maxTextures = 4096;

// The table buffer: the globals, then the textures, the entries and the
// jobs at fixed offsets. The globals are the palette, the fog table and
// the constants.
const globalWords = 1024 + 128 + 16;
const textureOffset = globalWords;
const entryOffset = textureOffset + maxTextures * textureWords;
const jobOffset = entryOffset + maxEntries * entryWords;
const tableWords = jobOffset + maxEntries * 2;

// The bindings of the program.
const _vramBinding = 0,
    _recordBinding = 1,
    _modifierBinding = 2,
    _tableBinding = 3,
    _outputBinding = 4;
const _vramBytes = 8 << 20;
const _bindings = [
  ComputeBinding(ComputeBindingKind.readOnlyStorage, _vramBytes),
  ComputeBinding(
      ComputeBindingKind.readOnlyStorage, maxRecords * recordWords * 4),
  ComputeBinding(
      ComputeBindingKind.readOnlyStorage, maxModifiers * modifierWords * 4),
  ComputeBinding(ComputeBindingKind.readOnlyStorage, tableWords * 4),
  // the tiles of the slots, and then the error codes of the entries
  ComputeBinding(ComputeBindingKind.storage, maxEntries * 1025 * 4),
  ComputeBinding(ComputeBindingKind.params, 16),
];

/// The messages of the error codes that the program reports for an entry,
/// for the checks that DcGpuRender makes per pixel.
const _errors = [
  '',
  'CORE nonfinite interpolated depth',
  'CORE shading perspective denominator is zero',
  'CORE perspective UV denominator is zero',
  'CORE secondary source pixel is uninitialized',
  'CORE secondary destination pixel is uninitialized',
  'CORE texture read outside retail VRAM',
  'CORE inverted color clamp bounds',
  'CORE nonfinite texture coordinate',
  'CORE invalid MIP footprint',
  'CORE modifier depth overflow',
  'CORE nonfinite shading depth',
  'CORE supersample perspective denominator is zero',
];

/// The lists of an entry, in the order of [DcComputeFrame.section].
const _lists = 6;

/// The records of one render.
class DcComputeFrame {
  // The lists of an entry: records, then modifier volume records.
  static const backgroundList = 0,
      opaqueList = 1,
      punchList = 2,
      translucentList = 3,
      opaqueModifierList = 4,
      translucentModifierList = 5;

  final records = Uint32List(maxRecords * recordWords);
  late final recordFloats = Float32List.view(records.buffer);
  final modifiers = Uint32List(maxModifiers * modifierWords);
  late final _modifierFloats = Float32List.view(modifiers.buffer);
  final tables = Uint32List(tableWords);
  late final _tableFloats = Float32List.view(tables.buffer);

  /// The output slot of each entry, or -1 when it does not write its tile.
  final slots = Int32List(maxEntries);
  int recordCount = 0, modifierCount = 0, textureCount = 0;
  int entryCount = 0, jobCount = 0, slotCount = 0;

  /// The entry whose lists failed a check, and the error.
  int failedEntry = -1;
  DcUnsupported? failure;

  /// The storage byte ranges that the textures of the frame read, as pairs
  /// of start and end.
  final spans = <int>[];

  final _starts = Int32List(_lists);
  final _views = <int, DcGpuTexture>{};
  final _textures = Map<DcGpuTexture, int>.identity();

  void clear() {
    recordCount = modifierCount = textureCount = 0;
    entryCount = jobCount = slotCount = 0;
    failedEntry = -1;
    failure = null;
    _views.clear();
    _textures.clear();
    spans.clear();
  }

  void fail(DcUnsupported error) {
    if (failure != null) return;
    failedEntry = entryCount;
    failure = error;
  }

  void constants(
      {required DcGpuPalette palette,
      required DcGpuFog fog,
      required int control,
      required int shadow,
      required int alphaReference}) {
    tables.setRange(0, 1024, palette.words);
    for (var i = 0; i < 128; i++) {
      tables[1024 + i] = fog.read(0x200 + i * 4);
    }
    const c = 1024 + 128;
    tables[c] = palette.control;
    tables[c + 1] = fog.tableColor;
    tables[c + 2] = fog.vertexColor;
    _tableFloats[c + 3] = fog.scale;
    tables[c + 4] = fog.read(0xc0);
    tables[c + 5] = fog.read(0xbc);
    tables[c + 6] = fog.invertedClamp ? 1 : 0;
    tables[c + 7] = control;
    tables[c + 8] = shadow;
    tables[c + 9] = alphaReference;
  }

  void beginEntry(
      {required bool drawsBackground,
      required bool backgroundShadow,
      required bool opaqueModifier,
      required int translucentMode,
      required bool writes,
      required double backgroundDepth}) {
    if (entryCount == maxEntries) {
      throw const DcUnsupported('CORE compute region entry capacity');
    }
    // An entry that keeps the tile of the one before it runs after it in
    // the same job.
    if (drawsBackground || jobCount == 0) {
      tables[jobOffset + jobCount * 2] = entryCount;
      tables[jobOffset + jobCount * 2 + 1] = 0;
      jobCount++;
    }
    final e = entryOffset + entryCount * entryWords;
    tables[e] = (drawsBackground ? 1 : 0) |
        (backgroundShadow ? 2 : 0) |
        (opaqueModifier ? 4 : 0) |
        (translucentMode << 3) |
        (writes ? 32 : 0);
    slots[entryCount] = writes ? slotCount++ : -1;
    tables[e + 1] = writes ? slots[entryCount] : 0;
    _tableFloats[e + 14] = backgroundDepth;
    _starts.fillRange(0, _lists, 0);
  }

  /// Starts [list] of the entry at the current record or modifier record.
  void section(int list) =>
      _starts[list] = list < opaqueModifierList ? recordCount : modifierCount;

  void endEntry() {
    final e = entryOffset + entryCount * entryWords;
    for (var list = 0; list < _lists; list++) {
      final end = list == translucentList
          ? recordCount
          : list == translucentModifierList
              ? modifierCount
              : _starts[list + 1];
      tables[e + 2 + list * 2] = _starts[list];
      tables[e + 3 + list * 2] = end - _starts[list];
    }
    tables[jobOffset + (jobCount - 1) * 2 + 1]++;
    entryCount++;
  }

  /// The word offset of a new record.
  int addRecord() {
    if (recordCount == maxRecords) {
      throw const DcUnsupported('CORE compute record capacity');
    }
    final at = recordCount++ * recordWords;
    records.fillRange(at, at + recordWords, 0);
    return at;
  }

  /// The edge function of the edge from p to q at [at] of the records, as
  /// a, b and c of a * x + b * y + c in the coordinates of the tile. Both
  /// directions of an edge get the same values but for the sign, so that
  /// two triangles with the edge in common cover each pixel once.
  void edge(int at, double px, double py, double qx, double qy, int originX,
      int originY) {
    _edge(recordFloats, at, px, py, qx, qy, originX, originY);
  }

  static void _edge(Float32List floats, int at, double px, double py, double qx,
      double qy, int originX, int originY) {
    final flip = py > qy || (py == qy && px > qx);
    if (flip) {
      final x = px, y = py;
      px = qx;
      py = qy;
      qx = x;
      qy = y;
    }
    final dx = qx - px, dy = qy - py;
    final a = -dy, b = dx;
    final c = dy * px - dx * py + a * originX + b * originY;
    floats[at] = flip ? -a : a;
    floats[at + 1] = flip ? -b : b;
    floats[at + 2] = flip ? -c : c;
  }

  /// A texture view of the frame, made once per TCW, TSP and control.
  DcGpuTexture view(
      Uint8List memory, DcGpuPalette palette, int tcw, int tsp, int control) {
    final key =
        (tcw & 0xffffffff) | ((tsp & 0x7ffff) << 32) | ((control & 31) << 51);
    return _views[key] ??= DcGpuTexture(memory,
        tcw: tcw, tsp: tsp, control: control, palette: palette);
  }

  /// The index of the descriptor of [texture].
  int texture(DcGpuTexture texture, int tsp) {
    final known = _textures[texture];
    if (known != null) return known;
    if (textureCount == maxTextures) {
      throw const DcUnsupported('CORE compute texture capacity');
    }
    final index = textureCount++;
    final t = textureOffset + index * textureWords;
    tables[t] = texture.width;
    tables[t + 1] = texture.height;
    tables[t + 2] = texture.stride;
    tables[t + 3] = texture.format;
    tables[t + 4] = texture.base;
    tables[t + 5] = texture.selector;
    tables[t + 6] = (texture.twiddled ? 1 : 0) |
        (texture.mipMapped ? 2 : 0) |
        (texture.compressed ? 4 : 0) |
        (texture.clampU ? 8 : 0) |
        (texture.clampV ? 16 : 0) |
        (texture.flipU ? 32 : 0) |
        (texture.flipV ? 64 : 0) |
        (texture.bilinear ? 128 : 0) |
        (texture.superSample ? 256 : 0) |
        (texture.trilinear ? 512 : 0);
    tables[t + 7] = texture.maxLevel;
    _tableFloats[t + 8] = ((tsp >> 8) & 15) / 4;
    tables[t + 9] = texture.filterMode;
    _textures[texture] = index;
    _span(texture);
    return index;
  }

  /// Adds the bytes of [texture] in both storage banks to [spans], as the
  /// texture cache of DcGpuRender finds them.
  void _span(DcGpuTexture texture) {
    final levels = texture.mipMapped ? texture.maxLevel + 1 : 1;
    var size = 0;
    for (var level = 0; level < levels; level++) {
      final w = texture.width >> level, h = texture.height >> level;
      size += (w < 1 ? 1 : w) * (h < 1 ? 1 : h);
    }
    final format = texture.format;
    final bytes = texture.compressed
        ? 0x808 + (size >> (format == 5 ? 4 : (format == 6 ? 3 : 2)))
        : 8 + (format == 5 ? size >> 1 : (format == 6 ? size : size * 2));
    final base = texture.base;
    final end = math.min(base + bytes, _vramBytes);
    if (end <= base) return;
    final low = (base >> 1) & 0x3ffffc, high = ((end - 1) >> 1) + 4;
    spans
      ..add(low)
      ..add(high)
      ..add(low + 0x400000)
      ..add(high + 0x400000);
  }

  /// A background material of one color: [color], or [shaded] where the
  /// modifier area shadows it.
  void flatBackground(int color, int shaded, int tsp,
      {required int area, required bool shadow}) {
    final r = addRecord();
    records[r + 1] = tsp;
    records[r + 2] = 0xffffffff;
    records[r + 4] = ((area + 1) & 3) | (shadow ? 16 : 0) | 128;
    records[r + 33] = color;
    records[r + 34] = shaded;
  }

  int _addModifier() {
    if (modifierCount == maxModifiers) {
      throw const DcUnsupported('CORE compute modifier capacity');
    }
    final at = modifierCount++ * modifierWords;
    modifiers.fillRange(at, at + modifierWords, 0);
    return at;
  }

  // The conservative bounds of DcGpuModifier.
  static int _lowBound(double value) =>
      value <= 1 ? 0 : (value >= 33 ? 32 : value.floor() - 1);
  static int _highBound(double value) =>
      value < -2 ? 0 : (value >= 30 ? 32 : value.ceil() + 2);

  static double _area(
          DcModifierPoint a, DcModifierPoint b, double x, double y) =>
      (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x);

  static bool _topLeft(DcModifierPoint a, DcModifierPoint b) =>
      b.y < a.y || (b.y == a.y && b.x > a.x);

  /// A triangle of a modifier volume, with the plane of its depths.
  void modifierTriangle(List<DcModifierPoint> vertices,
      List<DcModifierPoint> plane, int originX, int originY, double offset) {
    var a = vertices[0], b = vertices[1];
    final c = vertices[2];
    final determinant = _area(a, b, c.x, c.y);
    if (determinant == 0) return;
    if (determinant < 0) {
      final first = a;
      a = b;
      b = first;
    }
    final pa = plane[0], pb = plane[1], pc = plane[2];
    final planeArea = _area(pa, pb, pc.x, pc.y);
    double min3(double p, double q, double r) =>
        p < q ? (p < r ? p : r) : (q < r ? q : r);
    double max3(double p, double q, double r) =>
        p > q ? (p > r ? p : r) : (q > r ? q : r);
    final left = _lowBound(min3(a.x, b.x, c.x) - originX - offset),
        right = _highBound(max3(a.x, b.x, c.x) - originX - offset),
        top = _lowBound(min3(a.y, b.y, c.y) - originY - offset),
        bottom = _highBound(max3(a.y, b.y, c.y) - originY - offset);
    final m = _addModifier(), words = modifiers, floats = _modifierFloats;
    words[m] = 1 |
        (_topLeft(b, c) ? 0x100 : 0) |
        (_topLeft(c, a) ? 0x200 : 0) |
        (_topLeft(a, b) ? 0x400 : 0);
    words[m + 1] = left | (right << 8) | (top << 16) | (bottom << 24);
    _edge(floats, m + 2, b.x, b.y, c.x, c.y, originX, originY);
    _edge(floats, m + 5, c.x, c.y, a.x, a.y, originX, originY);
    _edge(floats, m + 8, a.x, a.y, b.x, b.y, originX, originY);
    // z = pc.z + (pa.z - pc.z) * wa + (pb.z - pc.z) * wb, with wa and wb
    // the edge functions of pb-pc and pc-pa over the plane area.
    final ka = (pa.z - pc.z) / planeArea, kb = (pb.z - pc.z) / planeArea;
    final ax = -(pc.y - pb.y), ay = pc.x - pb.x;
    final a0 = (pc.y - pb.y) * pb.x - (pc.x - pb.x) * pb.y;
    final bx = -(pa.y - pc.y), by = pa.x - pc.x;
    final b0 = (pa.y - pc.y) * pc.x - (pa.x - pc.x) * pc.y;
    floats[m + 11] = ka * ax + kb * bx;
    floats[m + 12] = ka * ay + kb * by;
    floats[m + 13] = pc.z +
        ka * (a0 + ax * originX + ay * originY) +
        kb * (b0 + bx * originX + by * originY);
  }

  /// The end of a volume: Inside Last (1) or Outside Last (2).
  void modifierClose(int instruction) {
    final m = _addModifier();
    modifiers[m] = instruction << 1;
  }
}

/// The program and the buffers that renders on one GPU share.
class _Program {
  _Program(ComputeSink sink)
      : program = sink.program(dcComputeShader, const ['tile'], _bindings,
            paramStride: 256, maxDispatches: 1),
        waits = sink.waits;

  final ComputeProgram program;
  final bool waits;
  final frame = DcComputeFrame();
  // The tiles of the slots and the error codes, as in the output binding.
  final output = Uint32List(maxEntries * 1025);
  final zeros = Uint32List(maxEntries);
  final dispatch = Uint32List(4);
  final params = Uint32List(64);

  /// The VRAM that the program holds, and the stamps of its pages when they
  /// were copied.
  Uint8List? memory;
  final copied = Int64List(_vramBytes >> 12);
}

/// Renders of the CORE of one VRAM on a compute program.
class DcCompute {
  /// Compiles the program on [sink]; throws if it cannot.
  DcCompute(ComputeSink sink, Uint8List memory)
      : this._(_Program(sink), memory, owner: true);

  DcCompute._(this._shared, this.memory, {required bool owner})
      : _owner = owner,
        _vramWords = Uint32List.view(
            memory.buffer, memory.offsetInBytes, memory.length >> 2);

  /// A compute of [memory] on the program of this one, for tools that make
  /// many renderers. Their renders must not overlap. Only this one disposes
  /// the program.
  DcCompute share(Uint8List memory) =>
      DcCompute._(_shared, memory, owner: false);

  final Uint8List memory;
  final _Program _shared;
  final bool _owner;
  final Uint32List _vramWords;
  late final _pages = DcVramPages.of(memory);
  bool _pending = false;

  ComputeProgram get _program => _shared.program;

  /// The records of the render in progress.
  DcComputeFrame get frame => _shared.frame;

  /// Copies the pages of VRAM that the textures of the frame read and that
  /// were written since they were copied.
  void _syncVram() {
    final shared = _shared, copied = shared.copied;
    final pages = memory.length >> 12;
    if (!identical(shared.memory, memory)) {
      _program.write(_vramBinding, 0, _vramWords);
      shared.memory = memory;
      for (var page = 0; page < pages; page++) {
        copied[page] = _pages.at(page << 12);
      }
      return;
    }
    final spans = frame.spans;
    for (var i = 0; i < spans.length; i += 2) {
      var page = spans[i] >> 12;
      final last = math.min((spans[i + 1] - 1) >> 12, pages - 1);
      while (page <= last) {
        if (_pages.at(page << 12) <= copied[page]) {
          page++;
          continue;
        }
        final first = page;
        while (page <= last && _pages.at(page << 12) > copied[page]) {
          copied[page] = _pages.at(page << 12);
          page++;
        }
        _program.write(
            _vramBinding, first << 12, _vramWords, first << 10, page << 10);
      }
    }
  }

  /// Runs the program on the recorded frame without waiting.
  void submit() {
    _syncVram();
    final f = frame, shared = _shared;
    _program
      ..write(_recordBinding, 0, f.records, 0, f.recordCount * recordWords)
      ..write(
          _modifierBinding, 0, f.modifiers, 0, f.modifierCount * modifierWords)
      ..write(_tableBinding, 0, f.tables, 0,
          textureOffset + f.textureCount * textureWords)
      ..write(_tableBinding, entryOffset * 4, f.tables, entryOffset,
          entryOffset + f.entryCount * entryWords)
      ..write(_tableBinding, jobOffset * 4, f.tables, jobOffset,
          jobOffset + f.jobCount * 2);
    final codes = f.slotCount * 1024;
    if (f.jobCount == 0) {
      shared.output.fillRange(codes, codes + f.entryCount, 0);
      return;
    }
    _program.write(_outputBinding, codes * 4, shared.zeros, 0, f.entryCount);
    shared.dispatch
      ..[0] = 0
      ..[1] = 16
      ..[2] = f.jobCount
      ..[3] = 1;
    shared.params
      ..[0] = f.jobCount
      ..[1] = f.slotCount;
    _program
      ..run(shared.dispatch, 1, shared.params, wait: false)
      ..prefetch(_outputBinding, 0, (codes + f.entryCount) * 4);
    _pending = true;
  }

  /// The results of the last [submit] while they are not on the host, on a
  /// sink that cannot wait for them; null when [finish] can read them.
  Future<void>? get fetching =>
      _pending && !_shared.waits ? _program.fetching : null;

  /// Waits for the program and reads its results.
  void finish() {
    if (!_pending) return;
    _pending = false;
    final f = frame;
    _program.read(
        _outputBinding,
        0,
        Uint32List.sublistView(
            _shared.output, 0, f.slotCount * 1024 + f.entryCount));
  }

  /// Throws the error that the recording of entry [index] met, if any.
  void check(int index) {
    final f = frame;
    if (index == f.failedEntry) throw f.failure!;
    if (index >= f.entryCount) {
      throw const DcUnsupported('CORE compute entry was not recorded');
    }
  }

  /// Takes the tile of entry [index] into [colors], or throws the error of
  /// the entry.
  void entry(int index, Uint32List colors) {
    final f = frame;
    check(index);
    finish();
    final code = _shared.output[f.slotCount * 1024 + index];
    if (code != 0) {
      throw DcUnsupported(
          code < _errors.length ? _errors[code] : 'CORE compute error $code');
    }
    final slot = f.slots[index];
    if (slot >= 0) colors.setRange(0, 1024, _shared.output, slot * 1024);
  }

  void dispose() {
    // Results that have not come are dropped with the program.
    if (fetching == null) finish();
    _pending = false;
    if (_owner) _program.dispose();
  }
}
