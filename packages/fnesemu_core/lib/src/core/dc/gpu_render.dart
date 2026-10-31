import 'dart:math' as math;
import 'dart:typed_data';

import '../../state.dart';
import '../../util/uint32list.dart';
import '../../util/uint8list.dart';
import 'fault.dart';
import 'gpu_fog.dart';
import 'gpu_math.dart';
import 'gpu_modifier.dart';
import 'gpu_palette.dart';
import 'gpu_texture.dart';
import 'vram_pages.dart';

/// Functional CORE display-list reader; raster precision and physical timing are pending.
/// Data structures and register fields follow System Architecture §§3.7.7–3.7.9, 8.4.2.
class DcGpuRender {
  DcGpuRender(this.memory, this.palette, {required this.onNormal})
      : _vramWords = ByteData.sublistView(memory),
        _vramHalves = Uint16List.view(
            memory.buffer, memory.offsetInBytes, memory.length ~/ 2);
  final Uint8List memory;
  final ByteData _vramWords;
  final Uint16List _vramHalves;
  late final _pages = DcVramPages.of(memory);
  final DcGpuPalette palette;
  final fog = DcGpuFog();
  final void Function(int) onNormal;
  int Function()? displayReadControl;
  int _stripLines = 0, _stripProduced = -1, _stripConsumed = -1;
  int _stripScaleRow = -1;
  bool _scaleSourceEnded = false, _stripDrainPending = false;
  bool _stripWaiting = false, _stripWatching = false;
  bool _stripQueued = false;
  bool get stripWatching => _stripWatching;

  bool stripReady(int row) =>
      !_stripWatching || row ~/ _stripLines <= _stripProduced;

  void consumeStripRow(int row, {required bool last}) {
    if (!_stripWatching) return;
    if ((row + 1) % _stripLines == 0 || last) {
      _stripConsumed = row ~/ _stripLines;
      _stripWaiting = _stripQueued;
    }
    if (last) {
      _stripWatching = false;
      if (_stripQueued) {
        _stripQueued = _stripWaiting = false;
        _remaining = 0;
        write(0x14, 1);
      }
    }
  }

  void stripHazard() {
    _remaining = 0;
    _stripWatching = _stripWaiting = false;
    _stripQueued = false;
    _stripScaleRow = -1;
    _scaleSourceEnded = _stripDrainPending = false;
    _scalerTiles.clear();
  }

  final _registers = <int, int>{};
  // [_registers] below 0x800 by word, for reads during rendering.
  final _registerWords = Uint32List(0x200);
  final _float = ByteData(4);
  final _colors = Uint32List(1024);
  final _secondary = Uint32List(1024);
  final _secondaryValid = Uint8List(1024);
  final _depth = Float64List(1024);
  // Constant sources for clearing the tile buffers with a block copy.
  static final _zeroBytes = Uint8List(1024), _zeroWords = Uint32List(1024);
  static final _noFragments = Int32List(1024)..fillRange(0, 1024, -1);
  final _scalerTiles = <int, Uint32List>{};
  Uint8List _shadowMask = Uint8List(1024);
  bool _shadowObject = false;
  int _materialArea = -1;
  late final modifier = DcGpuModifier(readWord: _word, culled: _culled);
  int _region = 0, _x = -1, _y = -1, _remaining = 0;
  int _sortMode = 0, _primitiveOrder = 0;
  // Opaque passes: 0 shades every passing fragment, 1 only resolves depth and
  // records in [_firstShaded] the last fragment that replaces the color, and
  // 2 shades only that fragment and the ones after it.
  int _visibility = 0;
  final _firstShaded = Int32List(1024);
  // The prepass pays off only when it hides textured fragments; every 16th
  // tile of a render samples that, and the others follow the sample.
  int _tileCount = 0, _hiddenFragments = 0, _shownFragments = 0;
  final _savedDepth = Float64List(1024);
  final _candidates = List<_Fragment?>.filled(1024, null);
  final _lastDepth = Float64List(1024);
  final _lastOrder = Int32List(1024);
  // Translucent fragments collected in one pass, linked per pixel.
  final _fragmentHead = Int32List(1024);
  var _fragmentCount = 0;
  var _fragmentNext = Int32List(1024), _fragmentOrder = Int32List(1024);
  var _fragmentColor = Uint32List(1024), _fragmentTsp = Uint32List(1024);
  var _fragmentDepth = Float64List(1024);
  var _fragmentWrite = Uint8List(1024), _fragmentSorted = Int32List(1024);
  bool get busy => _remaining != 0;
  int? get clocksToEvent => busy && !_stripWaiting ? _remaining : null;
  static const offsets = [
    0x14,
    0x20,
    0x2c,
    0x30,
    0x48,
    0x4c,
    0x60,
    0x64,
    0x68,
    0x6c,
    0x74,
    0x78,
    0x7c,
    0x80,
    0x84,
    0x88,
    0x8c,
    0x98,
    0xe4,
    0xf4,
    0x118,
    0x11c
  ];

  static bool handles(int offset) =>
      offsets.contains(offset) || DcGpuFog.handles(offset);

  void saveState(StateWriter writer) {
    writer.section('dc.gpu.render');
    writer.ints([
      memory.length,
      _region,
      _x,
      _y,
      _remaining,
      _sortMode,
      _primitiveOrder,
      _materialArea,
      if (_scalerTiles.isNotEmpty || _stripLines != 0) _scalerTiles.length,
      if (_stripLines != 0) ...[
        _stripLines,
        _stripProduced,
        _stripConsumed,
        (_stripWaiting ? 1 : 0) |
            (_stripWatching ? 2 : 0) |
            (_stripQueued ? 4 : 0),
        if (_stripScaleRow >= 0) ...[
          _stripScaleRow,
          (_scaleSourceEnded ? 1 : 0) | (_stripDrainPending ? 2 : 0)
        ]
      ]
    ]);
    for (final tile in _scalerTiles.entries) {
      writer.ints([tile.key, ...tile.value]);
    }
    writer.boolean(_shadowObject);
    writer.int32(_registers.length);
    for (final entry in _registers.entries) {
      writer.ints([entry.key, entry.value]);
    }
    writer.ints(_colors);
    writer.ints(_secondary);
    writer.bytes(_secondaryValid);
    writer.floats(_depth);
    writer.bytes(_shadowMask);
    writer.floats(_lastDepth);
    writer.ints(_lastOrder);
    for (final fragment in _candidates) {
      writer.boolean(fragment != null);
      if (fragment == null) continue;
      writer.float64(fragment.depth);
      writer.ints([fragment.color, fragment.tsp, fragment.order]);
      writer.boolean(fragment.writeDepth);
    }
    fog.saveState(writer);
  }

  void loadState(StateReader reader) {
    reader.section('dc.gpu.render');
    final v = reader.ints();
    if ((v.length != 8 &&
            v.length != 9 &&
            v.length != 13 &&
            v.length != 14 &&
            v.length != 15) ||
        v[0] != memory.length ||
        v[1] < 0 ||
        v[1] > 0xffffffff ||
        v[1] & 3 != 0 ||
        v[2] < -1 ||
        v[2] > 63 ||
        v[3] < -1 ||
        v[3] > 63 ||
        v[4] < 0 ||
        v[4] > 2 ||
        v[5] < 0 ||
        v[5] > 2 ||
        v[6] < 0 ||
        v[7] < -1 ||
        v[7] > 1) {
      throw const StateMismatch('GPU render scheduling state');
    }
    final scalerTiles = <int, Uint32List>{};
    final tileCount = v.length >= 9 ? v[8] : 0;
    if (v.length >= 13 &&
        (v[9] < 32 ||
            v[9] > 1024 ||
            v[9] % 32 != 0 ||
            v[10] < -1 ||
            v[10] > 63 ||
            v[11] < -1 ||
            v[11] > v[10] ||
            v[12] < 0 ||
            v[12] > 7 ||
            (v[12] & 4 != 0 &&
                (v[12] & 3 != 3 ||
                    v[4] == 0 ||
                    tileCount != 0 ||
                    v.length >= 14)) ||
            (v[12] & 1 != 0 && (v[4] == 0 || v[12] & 2 == 0)) ||
            (v.length == 14 &&
                (v[13] < 0 ||
                    v[13] > 63 ||
                    tileCount == 0 ||
                    v[4] == 0 ||
                    v[12] & 2 == 0)))) {
      throw const StateMismatch('GPU strip scheduling state');
    }
    if (v.length == 15 &&
        (v[13] < 0 ||
            v[13] > 63 ||
            (v[14] != 0 && v[14] != 2 && v[14] != 3) ||
            v[4] == 0 ||
            v[12] & 2 == 0 ||
            (v[14] != 0 && tileCount == 0))) {
      throw const StateMismatch('GPU streaming scaler state');
    }
    if (tileCount < 0 || tileCount > 4096 || (v[4] == 0 && tileCount != 0)) {
      throw const StateMismatch('GPU scaler tile count');
    }
    for (var i = 0; i < tileCount; i++) {
      final tile = reader.ints();
      if (tile.length != 1025 ||
          tile[0] < 0 ||
          tile[0] >= 4096 ||
          scalerTiles.containsKey(tile[0]) ||
          tile.skip(1).any((color) => color < 0 || color > 0xffffffff)) {
        throw const StateMismatch('GPU scaler tile');
      }
      scalerTiles[tile[0]] = Uint32List.fromList(tile.sublist(1));
    }
    final shadowObject = reader.boolean();
    final count = reader.int32(), registers = <int, int>{};
    if (count < 0 || count >= offsets.length) {
      throw const StateMismatch('GPU render register layout');
    }
    for (var i = 0; i < count; i++) {
      final entry = reader.ints();
      if (entry.length != 2 ||
          !offsets.contains(entry[0]) ||
          entry[0] == 0x14 ||
          registers.containsKey(entry[0]) ||
          entry[1] < 0 ||
          entry[1] & ~_registerMask(entry[0]) != 0) {
        throw const StateMismatch('GPU render register state');
      }
      registers[entry[0]] = entry[1];
    }
    final scale = registers[0xf4] ?? 0;
    if (tileCount != 0 &&
        (scale & 0xffff == 0 ||
            scale & 0xffff == 1024 ||
            (scale & 0x20000 != 0 && scale & 0xffff != 2048))) {
      throw const StateMismatch('GPU pending vertical scale configuration');
    }
    final colors = reader.ints(), secondary = reader.ints();
    final valid = reader.bytes(), depth = reader.floats();
    final shadow = reader.bytes(),
        lastDepth = reader.floats(),
        lastOrder = reader.ints();
    if ([
          colors.length,
          secondary.length,
          valid.length,
          depth.length,
          shadow.length,
          lastDepth.length,
          lastOrder.length
        ].any((length) => length != 1024) ||
        colors.any((x) => x < 0 || x > 0xffffffff) ||
        secondary.any((x) => x < 0 || x > 0xffffffff) ||
        valid.any((x) => x > 1) ||
        shadow.any((x) => x > 1) ||
        depth.any((x) => !x.isFinite) ||
        lastDepth.any((x) => !x.isFinite && x != double.negativeInfinity) ||
        lastOrder.any((x) => x < -0x80000000 || x > 0x7fffffff)) {
      throw const StateMismatch('GPU retained tile state');
    }
    final candidates = <_Fragment?>[];
    for (var i = 0; i < 1024; i++) {
      if (!reader.boolean()) {
        candidates.add(null);
        continue;
      }
      final z = reader.float64(), fields = reader.ints();
      final write = reader.boolean();
      if (!z.isFinite ||
          fields.length != 3 ||
          fields[0] < 0 ||
          fields[0] > 0xffffffff ||
          fields[1] < 0 ||
          fields[1] > 0xffffffff ||
          fields[2] < 0) {
        throw const StateMismatch('GPU sorted fragment state');
      }
      candidates.add(_Fragment(z, fields[0], fields[1], write, fields[2]));
    }
    final restoredFog = DcGpuFog()..loadState(reader);
    final fogWriter = StateWriter('dc.gpu.fog.transfer', 1, 0);
    restoredFog.saveState(fogWriter);
    final fogReader =
        StateReader(fogWriter.take(), 'dc.gpu.fog.transfer', 1, 0);
    fog.loadState(fogReader);
    fogReader.end();
    _region = v[1];
    _x = v[2];
    _y = v[3];
    _remaining = v[4];
    _stripLines = v.length >= 13 ? v[9] : 0;
    _stripProduced = v.length >= 13 ? v[10] : -1;
    _stripConsumed = v.length >= 13 ? v[11] : -1;
    _stripWaiting = v.length >= 13 && v[12] & 1 != 0;
    _stripWatching = v.length >= 13 && v[12] & 2 != 0;
    _stripQueued = v.length >= 13 && v[12] & 4 != 0;
    _stripScaleRow = v.length >= 14 ? v[13] : -1;
    _scaleSourceEnded = v.length == 14 || (v.length == 15 && v[14] & 1 != 0);
    _stripDrainPending = v.length == 14 || (v.length == 15 && v[14] & 2 != 0);
    _sortMode = v[5];
    _primitiveOrder = v[6];
    _materialArea = v[7];
    _shadowObject = shadowObject;
    _registers
      ..clear()
      ..addAll(registers);
    _mirrorRegisters();
    _colors.setAll(0, colors);
    _secondary.setAll(0, secondary);
    _secondaryValid.setAll(0, valid);
    _depth.setAll(0, depth);
    _shadowMask = shadow;
    _lastDepth.setAll(0, lastDepth);
    _lastOrder.setAll(0, lastOrder);
    _candidates.setAll(0, candidates);
    _scalerTiles
      ..clear()
      ..addAll(scalerTiles);
  }

  void reset() {
    _scaleSourceEnded = _stripDrainPending = false;
    _stripLines = 0;
    _stripScaleRow = -1;
    _stripProduced = _stripConsumed = -1;
    _stripWaiting = _stripWatching = false;
    _stripQueued = false;
    _scalerTiles.clear();
    fog.reset();
    _shadowMask.setRange(0, 1024, _zeroBytes);
    _shadowObject = false;
    _materialArea = -1;
    _secondaryValid.setRange(0, 1024, _zeroBytes);
    _registers
      ..clear()
      ..addAll(
          {0x7c: 0x7df77, 0x80: 7, 0x98: 0x402000, 0xf4: 0x400, 0x11c: 0xff});
    _mirrorRegisters();
    _remaining = _sortMode = _primitiveOrder = 0;
    _x = _y = -1;
  }

  int read(int offset) {
    if (DcGpuFog.handles(offset)) return fog.read(offset);
    if (offset == 0x14) throw const DcUnsupported('STARTRENDER is write-only');
    if (offset < 0x800 && offset & 3 == 0) return _registerWords[offset >> 2];
    return _registers[offset] ?? 0;
  }

  void _mirrorRegisters() {
    _registerWords.fillRange(0, _registerWords.length, 0);
    for (final MapEntry(:key, :value) in _registers.entries) {
      if (key < 0x800 && key & 3 == 0) _registerWords[key >> 2] = value;
    }
  }

  void write(int offset, int value) {
    if (offset == 0x14) {
      if (busy) {
        throw const DcUnsupported('CORE restart requires a pipeline reset');
      }
      final scale = read(0xf4), factor = scale & 0xffff;
      if (factor == 0) {
        throw const DcUnsupported('CORE zero vertical scale factor');
      }
      if (scale & 0x20000 != 0 && factor != 2048) {
        throw const DcUnsupported('CORE type-B interlace requires 1/2 scaling');
      }
      if (read(0x84) != 0) {
        throw const DcUnsupported('CORE perpendicular rejection is pending');
      }
      final display = displayReadControl?.call() ?? 0;
      final stripLines =
          display & 0x400000 != 0 ? ((display >> 17) & 31) * 32 : 0;
      if (display & 0x400000 != 0 && stripLines == 0) {
        throw const DcUnsupported('CORE zero strip-buffer size');
      }
      if (stripLines != 0 && read(0x68) & 2047 != 0) {
        throw const DcUnsupported('CORE X-clipped strip output is pending');
      }
      if (read(0x48) & 7 > 6) {
        throw const DcUnsupported('CORE prohibited framebuffer pack mode');
      }
      if (_stripWatching) {
        // Preserve both displayed buffers until the previous frame's last line is captured.
        _stripQueued = _stripWaiting = true;
        _remaining = 2;
        return;
      }
      _region = read(0x2c);
      _tileCount = _hiddenFragments = _shownFragments = 0;
      _stripLines = stripLines;
      _stripProduced = _stripConsumed = -1;
      _stripScaleRow = stripLines != 0 && factor != 1024 ? 0 : -1;
      _scaleSourceEnded = _stripDrainPending = false;
      _stripWaiting = false;
      _stripWatching = stripLines != 0;
      _scalerTiles.clear();
      _x = _y = -1;
      _remaining =
          2; // Functional tile deadline only; not a hardware render latency.
      return;
    }
    if (busy || (_stripWatching && const [0x4c, 0x60, 0x64].contains(offset))) {
      throw const DcUnsupported('CORE registers changed during rendering');
    }
    if (DcGpuFog.handles(offset)) return fog.write(offset, value);
    final masked = _registers[offset] = value & _registerMask(offset);
    if (offset < 0x800 && offset & 3 == 0) _registerWords[offset >> 2] = masked;
  }

  static int _registerMask(int offset) => switch (offset) {
        0x20 => 0xf00000,
        0x2c => 0xfffffc,
        0x30 => 0x10101,
        0x48 => 0xffffff,
        0x4c => 0x1ff,
        0x60 || 0x64 => 0x1fffffc,
        0x68 => 0x07ff07ff,
        0x6c => 0x03ff03ff,
        0x74 => 0x1ff,
        0x78 || 0x84 => 0x7fffffff,
        0x80 => 7,
        0x88 => 0xfffffff0,
        0x8c => 0x1fffffff,
        0xe4 => 0x31f1f,
        0xf4 => 0x7ffff,
        0x118 => 0xffff,
        0x11c => 0xff,
        _ => 0xffffffff,
      };

  int _word(int address) {
    if (address < 0 || address + 4 > memory.length || address & 3 != 0) {
      throw const DcUnsupported('CORE display-list read outside retail VRAM');
    }
    return memory.getUint32LE(address);
  }

  double _value(int bits) {
    _float.setUint32(0, bits, Endian.little);
    final result = _float.getFloat32(0, Endian.little);
    if (!result.isFinite) throw const DcUnsupported('CORE nonfinite parameter');
    return result;
  }

  double _number(int address) => _value(_word(address));

  void tickMasterClocks(int clocks) {
    if (!busy || _stripWaiting) return;
    _remaining -= clocks;
    while (_remaining <= 0) {
      try {
        if (_stripDrainPending) {
          if (!_flushVerticalScale(finalSource: _scaleSourceEnded)) {
            _remaining = 2;
            return;
          }
          _stripDrainPending = false;
          if (_scaleSourceEnded) {
            _scaleSourceEnded = false;
            _remaining = 0;
            onNormal(7);
            return;
          }
        }
        final last = _tile();
        if (_stripWaiting) {
          _remaining = 2;
          return;
        }
        if (last) {
          if (_scalerTiles.isNotEmpty) {
            if (_stripLines != 0) {
              _scaleSourceEnded = _stripDrainPending = true;
            }
            if (!_flushVerticalScale()) {
              _remaining = 2;
              return;
            }
          }
          _scaleSourceEnded = _stripDrainPending = false;
          _stripScaleRow = -1;
          _remaining = 0;
          onNormal(7); // Video/ISP/TSP completion after committed output.
          return;
        }
        _remaining += 2;
      } on DcUnsupported {
        _remaining = 2;
        rethrow;
      }
    }
  }

  bool _tile() {
    _primitiveOrder = 0;
    final control = _word(_region);
    final x = (control >> 2) & 63, y = (control >> 8) & 63;
    if (_stripLines != 0) {
      final strip = y * 32 ~/ _stripLines;
      if (read(0xf4) & 0xffff == 1024 && strip > _stripConsumed + 2) {
        _stripWaiting = true;
        return false;
      }
      final xStep = read(0xf4) & 0x10000 != 0 ? 2 : 1;
      final lastX = (((read(0x68) >> 16) + 1) * xStep - 1) ~/ 32;
      final ordered = _x < 0
          ? x == 0 && y == 0
          : y == _y
              ? x == _x + 1
              : y == _y + 1 && x == 0 && _x == lastX;
      if (!ordered || x > lastX) {
        throw const DcUnsupported(
            'CORE strip regions must cover consecutive horizontal rows');
      }
    }
    final type2 = read(0x7c) & 0x200000 != 0;
    final backgroundShadow =
        control & 0x40000000 == 0 && read(0x8c) & 0x08000000 != 0;
    _shadowMask.setRange(0, 1024, _zeroBytes);
    final drawsBackground = control & 0x40000000 == 0;
    if (!drawsBackground && (x != _x || y != _y)) {
      throw const DcUnsupported('CORE retained tile is not the preceding tile');
    }
    final opaque = _word(_region + 4), opaqueModifier = _word(_region + 8);
    final translucent = _word(_region + 12),
        translucentModifier = _word(_region + 16);
    final punch = type2 ? _word(_region + 20) : 0x80000000;
    if (opaqueModifier & 0x80000000 == 0) {
      if (drawsBackground) _background(x * 32, y * 32);
      // Resolve visible surface depths first, then shade the same tile with its area mask.
      // This replay is a functional implementation, not the hardware ISP/TSP scheduling.
      final colors = Uint32List.fromList(_colors),
          depths = Float64List.fromList(_depth);
      final secondary = Uint32List.fromList(_secondary);
      final valid = Uint8List.fromList(_secondaryValid);
      Uint8List mask;
      Uint8List? backgroundMask;
      try {
        _opaqueLists(opaque, punch, x * 32, y * 32, depthOnly: true);
        mask = modifier.evaluate(opaqueModifier & 0xfffffc, read(0x20), x * 32,
            y * 32, _depth, read(0x80) & 1 != 0 ? 0.5 : 0.0);
        if (backgroundShadow) {
          // Background color can remain visible through a blended foreground surface.
          backgroundMask = modifier.evaluate(
              opaqueModifier & 0xfffffc,
              read(0x20),
              x * 32,
              y * 32,
              depths,
              read(0x80) & 1 != 0 ? 0.5 : 0.0);
        }
      } finally {
        _colors.setAll(0, colors);
        _depth.setAll(0, depths);
        _secondary.setAll(0, secondary);
        _secondaryValid.setAll(0, valid);
      }
      if (backgroundMask != null) {
        _shadowMask = backgroundMask;
        _background(x * 32, y * 32);
      }
      _shadowMask = mask;
      _opaqueLists(opaque, punch, x * 32, y * 32);
    } else {
      _opaqueLists(opaque, punch, x * 32, y * 32, background: drawsBackground);
    }
    _shadowMask.setRange(0, 1024, _zeroBytes);
    if (translucent & 0x80000000 == 0) {
      final presort = type2 ? control & 0x20000000 != 0 : read(0x98) & 1 != 0;
      if (presort) {
        if (translucentModifier & 0x80000000 == 0) {
          throw const DcUnsupported(
              'CORE translucent modifiers require auto-sort');
        }
        _objects(translucent & 0xfffffc, x * 32, y * 32);
      } else {
        _sortedObjects(translucent & 0xfffffc, x * 32, y * 32,
            punch: false,
            modifierList: translucentModifier & 0x80000000 == 0
                ? translucentModifier & 0xfffffc
                : null);
      }
    }
    if (control & 0x10000000 == 0) _writeTile(x * 32, y * 32);
    _x = x;
    _y = y;
    _region += type2 ? 24 : 20;
    if (_stripLines != 0 &&
        read(0xf4) & 0xffff != 1024 &&
        control & 0x80000000 == 0 &&
        ((_word(_region) >> 8) & 63) > y) {
      _stripDrainPending = true;
      if (_flushVerticalScale(finalSource: false)) _stripDrainPending = false;
    }
    if (_stripLines != 0 &&
        read(0xf4) & 0xffff == 1024 &&
        (control & 0x80000000 != 0 ||
            ((_word(_region) >> 8) & 63) * 32 ~/ _stripLines >
                y * 32 ~/ _stripLines)) {
      _stripProduced = y * 32 ~/ _stripLines;
    }
    return control & 0x80000000 != 0;
  }

  /// [depthOnly] resolves the opaque list depths without shading it.
  /// [background] draws the background first, shading only the pixels that
  /// the opaque list leaves visible.
  void _opaqueLists(int opaque, int punch, int x, int y,
      {bool depthOnly = false, bool background = false}) {
    final prepass = depthOnly ||
        _tileCount++ & 15 == 0 ||
        _hiddenFragments * 8 > _shownFragments;
    if (opaque & 0x80000000 == 0 && prepass) {
      final order = _primitiveOrder;
      try {
        _visibility = 1;
        if (!depthOnly) {
          // Hidden fragments are shaded for nothing; find the visible ones first.
          _firstShaded.fillRange(0, 1024, -1);
          if (background) {
            _depth.fillRange(0, 1024, _value(read(0x88)));
          } else {
            _savedDepth.setAll(0, _depth);
          }
          _objects(opaque & 0xfffffc, x, y);
          _primitiveOrder = order;
          _visibility = 2;
          if (background) {
            _background(x, y);
          } else {
            _depth.setAll(0, _savedDepth);
          }
        }
        _objects(opaque & 0xfffffc, x, y);
      } finally {
        _visibility = 0;
      }
    } else {
      if (background) _background(x, y);
      if (opaque & 0x80000000 == 0) _objects(opaque & 0xfffffc, x, y);
    }
    if (punch & 0x80000000 == 0) {
      _sortedObjects(punch & 0xfffffc, x, y, punch: true);
    }
  }

  void _sortedObjects(int address, int x, int y,
      {required bool punch, int? modifierList}) {
    if (!punch && modifierList == null) {
      // Collected fragments never use the candidate buffer.
      _sortMode = 1;
      try {
        _sortTranslucent(address, x, y);
      } finally {
        _sortMode = 0;
      }
      return;
    }
    _sortMode = punch ? 2 : 1;
    try {
      if (!punch) {
        _lastDepth.fillRange(0, 1024, double.negativeInfinity);
        _lastOrder.fillRange(0, 1024, -1);
      }
      var more = true;
      while (more) {
        _candidates.fillRange(0, 1024, null);
        _primitiveOrder = 0;
        if (modifierList != null) _shadowMask.setRange(0, 1024, _zeroBytes);
        _objects(address, x, y);
        if (modifierList != null && _candidates.any((value) => value != null)) {
          final surfaces = Float64List(1024), active = Uint8List(1024);
          for (var i = 0; i < 1024; i++) {
            final fragment = _candidates[i];
            if (fragment != null) {
              surfaces[i] = fragment.depth;
              active[i] = 1;
            }
          }
          _shadowMask = modifier.evaluate(modifierList, read(0x20), x, y,
              surfaces, read(0x80) & 1 != 0 ? 0.5 : 0.0,
              active: active);
          _candidates.fillRange(0, 1024, null);
          _primitiveOrder = 0;
          _objects(address, x, y);
        }
        more = false;
        for (var i = 0; i < 1024; i++) {
          final fragment = _candidates[i];
          if (fragment == null) continue;
          if (punch) {
            // System Architecture §3.4.3: accepted punch-through pixels are opaque.
            _storeColor(
                i,
                _sourceColor(i, fragment.color, fragment.tsp) | 0xff000000,
                fragment.tsp);
          } else {
            _composite(i, fragment.color, fragment.tsp);
            _lastDepth[i] = fragment.depth;
            _lastOrder[i] = fragment.order;
            more = true;
          }
          if (fragment.writeDepth) _depth[i] = fragment.depth;
        }
        if (punch) {
          break; // The nearest accepted fragment is already the final opaque result.
        }
      }
    } finally {
      _sortMode = 0;
      _candidates.fillRange(0, 1024, null);
    }
  }

  /// Auto-sort without modifiers: rasterize once, then composite each pixel's
  /// fragments in ascending (depth, input order). This gives the same order as
  /// peeling one layer per pass, since depth writes only grow along that order.
  void _sortTranslucent(int address, int x, int y) {
    _sortMode = 3;
    _fragmentHead.setRange(0, 1024, _noFragments);
    _fragmentCount = 0;
    _primitiveOrder = 0;
    _objects(address, x, y);
    if (_fragmentCount == 0) return;
    if (_fragmentSorted.length < _fragmentCount) {
      _fragmentSorted = Int32List(_fragmentNext.length);
    }
    final sorted = _fragmentSorted, depth = _fragmentDepth;
    final order = _fragmentOrder;
    for (var i = 0; i < 1024; i++) {
      var count = 0;
      for (var f = _fragmentHead[i]; f >= 0; f = _fragmentNext[f]) {
        final z = depth[f], o = order[f];
        var j = count++;
        while (j > 0) {
          final g = sorted[j - 1], zg = depth[g];
          if (zg < z || (zg == z && order[g] < o)) break;
          sorted[j] = g;
          j--;
        }
        sorted[j] = f;
      }
      for (var k = 0; k < count; k++) {
        final f = sorted[k];
        _composite(i, _fragmentColor[f], _fragmentTsp[f]);
        if (_fragmentWrite[f] != 0) _depth[i] = depth[f];
      }
    }
  }

  void _addFragment(
      int index, double z, int color, int tsp, bool writeDepth, int order) {
    final f = _fragmentCount++;
    if (f == _fragmentNext.length) {
      final size = f * 2;
      _fragmentNext = Int32List(size)..setAll(0, _fragmentNext);
      _fragmentOrder = Int32List(size)..setAll(0, _fragmentOrder);
      _fragmentColor = Uint32List(size)..setAll(0, _fragmentColor);
      _fragmentTsp = Uint32List(size)..setAll(0, _fragmentTsp);
      _fragmentDepth = Float64List(size)..setAll(0, _fragmentDepth);
      _fragmentWrite = Uint8List(size)..setAll(0, _fragmentWrite);
    }
    _fragmentNext[f] = _fragmentHead[index];
    _fragmentHead[index] = f;
    _fragmentOrder[f] = order;
    _fragmentColor[f] = color;
    _fragmentTsp[f] = tsp;
    _fragmentDepth[f] = z;
    _fragmentWrite[f] = writeDepth ? 1 : 0;
  }

  final _textureCaches = <int, DcTextureCache>{};
  int _textureCacheTexels = 0;

  /// Builds a texture view with decoded texels shared across tiles and frames.
  /// The cache is revalidated against VRAM page stamps and the palette version.
  DcGpuTexture _cachedTexture(int tcw, int tsp) {
    final control = read(0xe4);
    final texture = DcGpuTexture(memory,
        tcw: tcw, tsp: tsp, control: control, palette: palette);
    // Bump texels depend on per-pixel parameters and are not cached.
    if (texture.format == 4) return texture;
    final width = texture.width, height = texture.height;
    final levels = texture.mipMapped ? texture.maxLevel + 1 : 1;
    final offsets = Int32List(levels);
    var size = 0;
    for (var level = 0; level < levels; level++) {
      offsets[level] = size;
      final w = width >> level, h = height >> level;
      size += (w < 1 ? 1 : w) * (h < 1 ? 1 : h);
    }
    if (size > 1 << 20) return texture;
    final key =
        (tcw & 0xffffffff) | ((tsp & 0x3f) << 32) | ((control & 31) << 38);
    var cache = _textureCaches[key];
    if (cache == null) {
      // At most 128 caches and 8M texels, or 64 MiB of texels and stamps.
      if (_textureCaches.length >= 128 ||
          _textureCacheTexels + size > 1 << 23) {
        _textureCaches.clear();
        _textureCacheTexels = 0;
      }
      cache = _textureCaches[key] = DcTextureCache(size, offsets);
      _textureCacheTexels += size;
    }
    // A byte span in the 64-bit texture space, mapped to both
    // storage banks. Texels past the end of VRAM are never read.
    final base = texture.base;
    final format = texture.format;
    // VQ indices cover 2x2 texels, or 4x4 and 4x2 for 4 and 8 bpp palettes.
    final bytes = texture.compressed
        ? 0x808 + (size >> (format == 5 ? 4 : (format == 6 ? 3 : 2)))
        : 8 + (format == 5 ? size >> 1 : (format == 6 ? size : size * 2));
    final end = math.min(base + bytes, memory.length);
    final low = (base >> 1) & 0x3ffffc, high = ((end - 1) >> 1) + 4;
    final written = high > low
        ? math.max(_pages.newest(low, high),
            _pages.newest(low + 0x400000, high + 0x400000))
        : _pages.clock;
    // Only indexed textures depend on the palette entries they select.
    final paletteVersion = texture.format == 5 || texture.format == 6
        ? palette.versionOf(texture.selector, texture.format == 5 ? 16 : 256)
        : 0;
    texture.cache = cache;
    if (cache.paletteVersion != paletteVersion) {
      cache.invalidate();
    } else if (written > cache.checked) {
      if (texture.partialInvalidation && high > low) {
        // Drop only texels in the 8 KiB spans of written pages.
        for (var span = base & ~8191; span < end; span += 8192) {
          final page = (span >> 1) & 0x3ff000;
          if (_pages.at(page) > cache.checked ||
              _pages.at(page + 0x400000) > cache.checked) {
            texture.invalidateSpan(span, span + 8192);
          }
        }
      } else {
        cache.invalidate();
      }
    }
    cache.checked = _pages.clock;
    cache.paletteVersion = paletteVersion;
    return texture;
  }

  void _objects(int address, int x, int y) {
    final visited = <int>{};
    for (;; address += 4) {
      if (!visited.add(address)) {
        throw const DcUnsupported('CORE cyclic object list');
      }
      final pointer = _word(address);
      if (pointer >> 29 == 7) {
        if (pointer & 0x10000000 != 0) return;
        address = (pointer & 0xfffffc) - 4;
        continue;
      }
      final kind = pointer & 0x80000000 == 0 ? 0 : pointer >> 29;
      if (kind != 0 && kind != 4 && kind != 5) {
        throw const DcUnsupported('CORE prohibited object pointer');
      }
      var parameter = read(0x20) + ((pointer & 0x1fffff) * 4);
      final count = kind == 0 ? 1 : ((pointer >> 25) & 15) + 1;
      for (var i = 0; i < count; i++) {
        parameter = _drawObject(parameter, pointer, x, y, kind);
      }
    }
  }

  int _drawObject(int parameter, int pointer, int x, int y, int kind) {
    final isp = _word(parameter);
    _shadowObject = pointer & 0x01000000 != 0;
    final twoVolumes = _shadowObject && read(0x74) & 0x100 == 0;
    final textured = isp & 0x02000000 != 0;
    final hasOffset = textured && isp & 0x01000000 != 0;
    final attributes = 1 +
        (textured ? (isp & 0x00400000 != 0 ? 1 : 2) + (hasOffset ? 1 : 0) : 0);
    if (((pointer >> 21) & 7) != attributes) {
      throw const DcUnsupported(
          'CORE object skip does not match its parameters');
    }
    final stride = 3 + attributes * (twoVolumes ? 2 : 1);
    final header = twoVolumes ? 5 : 3;
    void drawMaterial(int slot) {
      final tsp = _word(parameter + 4 + slot * 8);
      final sourceSecondary = tsp & 0x02000000 != 0;
      final texture = textured && !sourceSecondary
          ? _cachedTexture(_word(parameter + 8 + slot * 8), tsp)
          : null;
      if (texture?.format == 4 && (!hasOffset || isp & 0x00800000 != 0)) {
        throw const DcUnsupported(
            'CORE bump mapping requires offset parameters and flat shading');
      }
      if (_sortMode == 2 && texture?.trilinear == true) {
        throw const DcUnsupported('CORE trilinear punch-through is prohibited');
      }
      List<_Vertex> vertices(int first, int count) => [
            for (var i = 0; i < count; i++)
              _vertex(parameter + header * 4 + (first + i) * stride * 4, isp,
                  attributeOffset: slot * attributes * 4,
                  ignoreShading: sourceSecondary)
          ];
      if (kind == 4) {
        _triangle(vertices(0, 3), isp, tsp, texture, x, y);
      } else if (kind == 5) {
        final first = vertices(0, 3),
            fourth = parameter + header * 4 + 3 * stride * 4;
        // Only X/Y of D are defined; both materials derive their attributes from ABC.
        final d = _Vertex(_number(fourth), _number(fourth + 4), 0, 0);
        _quad([...first, d], isp, tsp, texture, x, y);
      } else {
        final mask = (pointer >> 25) & 63;
        for (var triangle = 0; triangle < 6; triangle++) {
          if (mask & (1 << (5 - triangle)) == 0) continue;
          final strip = vertices(triangle, 3);
          if (triangle.isOdd) {
            final first = strip[0];
            strip[0] = strip[1];
            strip[1] = first;
          }
          _triangle(strip, isp, tsp, texture, x, y);
        }
      }
    }

    if (twoVolumes) {
      final previousArea = _materialArea, order = _primitiveOrder;
      try {
        _materialArea = 0;
        drawMaterial(0);
        final nextOrder = _primitiveOrder;
        _primitiveOrder = order;
        _materialArea = 1;
        drawMaterial(1);
        // The two materials belong to one primitive, including auto-sort tie ordering.
        _primitiveOrder = nextOrder;
      } finally {
        _materialArea = previousArea;
      }
    } else {
      drawMaterial(0);
    }
    return kind == 4
        ? parameter + (header + 3 * stride) * 4
        : kind == 5
            ? parameter + (header + 4 * stride) * 4
            : parameter;
  }

  _Vertex _vertex(int address, int isp,
      {bool ignoreShading = false, int attributeOffset = 0}) {
    if (ignoreShading) {
      return _Vertex(
          _number(address), _number(address + 4), _number(address + 8), 0);
    }
    var cursor = address + 12 + attributeOffset;
    var u = 0.0, v = 0.0;
    final textured = isp & 0x02000000 != 0;
    if (textured) {
      if (isp & 0x00400000 != 0) {
        final uv = _word(cursor);
        u = _value(uv & 0xffff0000);
        v = _value((uv & 0xffff) << 16);
        cursor += 4;
      } else {
        u = _number(cursor);
        v = _number(cursor + 4);
        cursor += 8;
      }
    }
    final color = _word(cursor);
    final offset = textured && isp & 0x01000000 != 0 ? _word(cursor + 4) : 0;
    return _Vertex(
        _number(address), _number(address + 4), _number(address + 8), color,
        u: u, v: v, offsetColor: offset);
  }

  double _edge(_Vertex a, _Vertex b, double x, double y) =>
      (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x);

  bool _topLeft(_Vertex a, _Vertex b) => b.y < a.y || (b.y == a.y && b.x > a.x);

  bool _culled(double area, int isp) {
    final cull = (isp >> 27) & 3;
    return area == 0 ||
        (cull != 0 && area.abs() < _value(read(0x78))) ||
        (cull == 2 && area < 0) ||
        (cull == 3 && area > 0);
  }

  void _quad(List<_Vertex> vertices, int isp, int tsp, DcGpuTexture? texture,
      int x, int y) {
    final a = vertices[0], b = vertices[1], c = vertices[2], d = vertices[3];
    final area = _edge(a, b, c.x, c.y);
    if (_culled(area, isp)) return;
    for (var i = 1; i < 4; i++) {
      final e = vertices[i],
          f = vertices[(i + 1) & 3],
          g = vertices[(i + 2) & 3];
      if (_edge(e, f, g.x, g.y) * area.sign < 0) {
        throw const DcUnsupported(
            'CORE concave or crossed quad needs hardware validation');
      }
    }
    final plane = [a, b, c];
    _triangle(plane, isp, tsp, texture, x, y, plane: plane);
    _triangle([a, c, d], isp, tsp, texture, x, y, plane: plane);
  }

  void _background(int x, int y) {
    final tag = read(0x8c), skip = (tag >> 24) & 7;
    final shadow = tag & 0x08000000 != 0;
    final twoVolumes = shadow && read(0x74) & 0x100 == 0;
    final parameter = read(0x20) + (((tag >> 3) & 0x1fffff) * 4);
    final isp = _word(parameter);
    final textured = isp & 0x02000000 != 0, gouraud = isp & 0x00800000 != 0;
    final expected = 1 +
        (textured ? (isp & 0x00400000 != 0 ? 1 : 2) : 0) +
        (textured && isp & 0x01000000 != 0 ? 1 : 0);
    if (skip != expected) {
      throw const DcUnsupported(
          'CORE background vertex stride does not match its format');
    }
    final depth = _value(read(0x88));
    if (!depth.isFinite) {
      throw const DcUnsupported('CORE nonfinite background depth');
    }
    final header = twoVolumes ? 5 : 3;
    final stride = 3 + skip * (twoVolumes ? 2 : 1);
    _shadowObject = shadow;
    _secondaryValid.setRange(0, 1024, _zeroBytes);
    for (var i = 0; i < 1024; i++) {
      _depth[i] = depth;
    }
    // Primary pixels not initialized by the background are provisionally transparent black.
    // The physical initial contents when only the secondary buffer is written are unknown.
    _colors.setRange(0, 1024, _zeroWords);

    void material(int slot) {
      final tsp = _word(parameter + 4 + slot * 8);
      if (tsp & 0x02000000 != 0) {
        throw const DcUnsupported(
            'CORE background secondary source is uninitialized');
      }
      if (!textured && !gouraud) {
        final vertex = (tag & 7) + 2;
        var color =
            _word(parameter + (header + vertex * stride + 3 + slot * skip) * 4);
        var shaded = shadow && !twoVolumes ? _shadowColor(color) : color;
        if (tsp & 0x100000 == 0) {
          color |= 0xff000000;
          shaded |= 0xff000000;
        }
        color = fog.apply(color, depth, 0, tsp, hasOffset: false);
        if (shadow && !twoVolumes) {
          shaded = fog.apply(shaded, depth, 0, tsp, hasOffset: false);
        }
        if (!shadow && tsp & 0x01000000 == 0) {
          for (var i = 0; i < 1024; i++) {
            _colors[i] = color;
          }
          return;
        }
        for (var i = 0; i < 1024; i++) {
          if (twoVolumes && _shadowMask[i] != slot) continue;
          _storeColor(
              i,
              shadow && !twoVolumes && _shadowMask[i] != 0 ? shaded : color,
              tsp);
        }
        return;
      }
      final vertices = [
        for (var i = 0; i < 3; i++)
          _vertex(parameter + (header + ((tag & 7) + i) * stride) * 4, isp,
              attributeOffset: slot * skip * 4)
      ];
      final area =
          _edge(vertices[0], vertices[1], vertices[2].x, vertices[2].y);
      if (!area.isFinite || area == 0) {
        throw const DcUnsupported(
            'CORE background shading plane is degenerate');
      }
      final texture = textured
          ? _cachedTexture(_word(parameter + 8 + slot * 8), tsp)
          : null;
      if (texture?.format == 4 && (isp & 0x01000000 == 0 || gouraud)) {
        throw const DcUnsupported(
            'CORE background bump requires offset and flat shading');
      }
      final coverage = [
        _Vertex(x - 1.0, y - 1.0, depth, 0),
        _Vertex(x + 65.0, y - 1.0, depth, 0),
        _Vertex(x - 1.0, y + 65.0, depth, 0)
      ];
      _triangle(coverage, isp, tsp, texture, x, y,
          plane: vertices, backgroundDepth: depth);
    }

    final previousArea = _materialArea;
    try {
      if (twoVolumes) {
        _materialArea = 0;
        material(0);
        _materialArea = 1;
        material(1);
      } else {
        _materialArea = -1;
        material(0);
      }
    } finally {
      _materialArea = previousArea;
    }
  }

  static int _tileFloor(double value) =>
      value <= 0 ? 0 : (value >= 32 ? 32 : value.floor());

  static int _tileCeiling(double value) =>
      value < 0 ? 0 : (value >= 31 ? 32 : value.ceil() + 1);

  @pragma('vm:unsafe:no-bounds-checks')
  void _triangle(List<_Vertex> vertices, int isp, int tsp,
      DcGpuTexture? texture, int originX, int originY,
      {List<_Vertex>? plane, double? backgroundDepth}) {
    // Keep the per-pixel depth unboxed: never merge it with a nullable double.
    final background = backgroundDepth != null;
    final backgroundZ = backgroundDepth ?? 0.0;
    final order = background ? -1 : _primitiveOrder++;
    var a = vertices[0], b = vertices[1];
    final c = vertices[2];
    var area = _edge(a, b, c.x, c.y);
    if (plane == null ? _culled(area, isp) : area == 0) return;
    if (area < 0) {
      final first = a;
      a = b;
      b = first;
      area = -area;
    }
    if (!area.isFinite) {
      throw const DcUnsupported('CORE raster determinant overflow');
    }
    final sa = plane?[0] ?? a, sb = plane?[1] ?? b, sc = plane?[2] ?? c;
    final shadeArea = plane == null ? area : _edge(sa, sb, sc.x, sc.y);
    List<double>? mipNumerators;
    if (texture?.mipMapped == true) {
      final values = [sa, sb, sc];
      final dx = [
        (sb.y - sc.y) / shadeArea,
        (sc.y - sa.y) / shadeArea,
        (sa.y - sb.y) / shadeArea
      ];
      final dy = [
        (sc.x - sb.x) / shadeArea,
        (sa.x - sc.x) / shadeArea,
        (sb.x - sa.x) / shadeArea
      ];
      final origin = [
        _edge(sb, sc, 0, 0) / shadeArea,
        _edge(sc, sa, 0, 0) / shadeArea,
        _edge(sa, sb, 0, 0) / shadeArea
      ];
      double dot(List<double> weights, int component) {
        var result = 0.0;
        for (var i = 0; i < 3; i++) {
          final vertex = values[i];
          result += weights[i] *
              vertex.z *
              (component == 0
                  ? vertex.u
                  : component == 1
                      ? vertex.v
                      : 1);
        }
        return result;
      }

      final reference = plane?[0] ?? vertices[0];
      final precise = isp & 0x100000 != 0;
      final rz = precise ? reference.z : dot(origin, 2);
      final ru = precise ? reference.u * reference.z : dot(origin, 0);
      final rv = precise ? reference.v * reference.z : dot(origin, 1);
      // Dcalc=0 uses constants at the screen origin; Dcalc=1 uses the original first vertex.
      mipNumerators = [
        dot(dx, 0) * rz - dot(dx, 2) * ru,
        dot(dx, 1) * rz - dot(dx, 2) * rv,
        dot(dy, 0) * rz - dot(dy, 2) * ru,
        dot(dy, 1) * rz - dot(dy, 2) * rv
      ];
    }
    final control = read(0x80);
    final offset = control & 1 != 0 ? 0.5 : 0.0;
    final pixelOffset = control & 2 != 0 ? 0.5 : 0.0;
    final texOffset = control & 4 != 0 ? 0.5 : 0.0;
    final samePosition = offset == pixelOffset;
    final shadowIntensity = read(0x74) & 0x100 != 0;
    final alphaReference = _sortMode == 2 ? read(0x11c) : 0;
    final gouraud = isp & 0x00800000 != 0;
    final tl0 = _topLeft(b, c), tl1 = _topLeft(c, a), tl2 = _topLeft(a, b);
    final minX = (a.x < b.x ? a.x : b.x) < c.x ? (a.x < b.x ? a.x : b.x) : c.x;
    final maxX = (a.x > b.x ? a.x : b.x) > c.x ? (a.x > b.x ? a.x : b.x) : c.x;
    final minY = (a.y < b.y ? a.y : b.y) < c.y ? (a.y < b.y ? a.y : b.y) : c.y;
    final maxY = (a.y > b.y ? a.y : b.y) > c.y ? (a.y > b.y ? a.y : b.y) : c.y;
    // Keep conservative endpoint pixels; edge tests still decide coverage.
    final left = _tileFloor(minX - originX - offset);
    final right = _tileCeiling(maxX - originX - offset);
    final top = _tileFloor(minY - originY - offset);
    final bottom = _tileCeiling(maxY - originY - offset);
    final inverseArea = 1 / area, inverseShade = 1 / shadeArea;
    // Shading-plane weights as linear functions of the sample position.
    final ax = (sb.y - sc.y) * inverseShade,
        ay = (sc.x - sb.x) * inverseShade,
        a0 = ((sc.y - sb.y) * sb.x - (sc.x - sb.x) * sb.y) * inverseShade;
    final bx = (sc.y - sa.y) * inverseShade,
        by = (sa.x - sc.x) * inverseShade,
        b0 = ((sa.y - sc.y) * sc.x - (sa.x - sc.x) * sc.y) * inverseShade;
    final cx = (sa.y - sb.y) * inverseShade,
        cy = (sb.x - sa.x) * inverseShade,
        c0 = ((sb.y - sa.y) * sa.x - (sb.x - sa.x) * sa.y) * inverseShade;
    final za = sa.z, zb = sb.z, zc = sc.z;
    final uza = sa.u * za, uzb = sb.u * zb, uzc = sc.u * zc;
    final vza = sa.v * za, vzb = sb.v * zb, vzc = sc.v * zc;
    final sameTexture = texOffset == pixelOffset;
    // Edge-function factors, evaluated in the same order as [_edge].
    final e0x = c.x - b.x, e0y = c.y - b.y;
    final e1x = a.x - c.x, e1y = a.y - c.y;
    final e2x = b.x - a.x, e2y = b.y - a.y;
    // Untextured fragments with equal vertex colors, no shadow and
    // depth-independent fog all share one color.
    final fogMode = (tsp >> 22) & 3;
    final flat = texture == null &&
        !(_shadowObject && shadowIntensity) &&
        (fogMode == 1 || fogMode == 2) &&
        (tsp & 0x02000000 != 0 ||
            !gouraud ||
            (sa.color == sb.color &&
                sb.color == sc.color &&
                sa.offsetColor == sb.offsetColor &&
                sb.offsetColor == sc.offsetColor));
    var flatColor = 0;
    // Opaque bilinear fragments sampled and shaded where they are rasterized.
    final quick = texture != null &&
        texture.plainBilinear &&
        plane == null &&
        !background &&
        samePosition &&
        sameTexture &&
        _sortMode == 0 &&
        tsp & 0x02000000 == 0 &&
        !(_shadowObject && shadowIntensity);
    final quickFog = (tsp >> 22) & 3 != 2 || tsp & 0x200000 != 0;
    final replace = tsp & 0xff000000 == 0x20000000;
    final sameColors =
        !gouraud || (sa.color == sb.color && sb.color == sc.color);
    final sameOffsets = !gouraud ||
        (sa.offsetColor == sb.offsetColor && sb.offsetColor == sc.offsetColor);
    final opaqueAlpha = tsp & 0x100000 == 0 ? 0xff000000 : 0;
    if (flat && tsp & 0x02000000 == 0) {
      flatColor = sc.color;
      if (tsp & 0x100000 == 0) flatColor |= 0xff000000;
      flatColor =
          fog.apply(flatColor, 0, sc.offsetColor, tsp, hasOffset: false);
    }
    if (background && flat && _visibility == 0 && _materialArea < 0) {
      // The background coverage triangle contains the whole tile.
      if (tsp & 0x01000000 != 0) {
        _secondary.fill(0, 1024, flatColor);
        _secondaryValid.fillRange(0, 1024, 1);
      } else {
        _colors.fill(0, 1024, flatColor);
      }
      return;
    }
    // The common case of [quick] with loop-invariant tests hoisted.
    final quickRows = quick &&
        sameColors &&
        sameOffsets &&
        _materialArea < 0 &&
        _visibility == 0;
    final compare = isp >> 29, writeDepth = isp & 0x04000000 == 0;
    final quickColor = sc.color | opaqueAlpha, quickOffset = sc.offsetColor;
    final shadeMode = (tsp >> 6) & 3, quickGray = quickColor & 255;
    final gray =
        (shadeMode == 1 || shadeMode == 3 && quickColor >>> 24 == 255) &&
            quickColor & 0xffffff == quickGray * 0x10101;
    final ignoredAlpha = tsp & 0x80000 != 0 ? 0xff000000 : 0;
    final fogOffset = isp & 0x01000000 != 0;
    final vbx = b.x, vcx = c.x, vax = a.x;
    final depthBuffer = _depth, colorBuffer = _colors;
    if (quickRows) texture.decodeAll();
    final dz = -(za * e0y + zb * e1y + zc * e2y) * inverseArea,
        duz = -(uza * e0y + uzb * e1y + uzc * e2y) * inverseArea,
        dvz = -(vza * e0y + vzb * e1y + vzc * e2y) * inverseArea;
    // With one depth, texel positions step linearly in 16.16 fixed point.
    final uScale = quickRows ? 65536 * texture.width / za : 0.0,
        vScale = quickRows ? 65536 * texture.height / za : 0.0;
    final affine = quickRows &&
        za == zb &&
        zb == zc &&
        (duz * uScale).abs() < 1 << 40 &&
        (dvz * vScale).abs() < 1 << 40;
    final dsu = affine ? (duz * uScale).toInt() : 0,
        dsv = affine ? (dvz * vScale).toInt() : 0;
    for (var y = top; y < bottom; y++) {
      // Narrow the row to the columns each edge can accept, with a one-pixel
      // margin; the exact edge tests below still decide coverage.
      final rowY = originY + y + offset, base = originX + offset;
      var rowLeft = left, rowRight = right;
      for (var edge = 0; edge < 3; edge++) {
        final p = edge == 0 ? b : (edge == 1 ? c : a);
        final q = edge == 0 ? c : (edge == 1 ? a : b);
        final slope = q.y - p.y;
        if (slope == 0) continue;
        final limit = p.x + (q.x - p.x) * (rowY - p.y) / slope - base;
        if (slope > 0) {
          final bound = limit + 2;
          if (bound < rowRight) {
            rowRight = bound < rowLeft ? rowLeft : bound.toInt();
          }
        } else {
          final bound = limit - 1;
          if (bound > rowLeft) {
            rowLeft = bound > rowRight ? rowRight : bound.toInt();
          }
        }
      }
      final py = rowY;
      final row0 = e0x * (py - b.y),
          row1 = e1x * (py - c.y),
          row2 = e2x * (py - a.y);
      if (quickRows) {
        // Edge and plane values step linearly along the row.
        final x0 = originX + rowLeft + offset;
        var e0 = row0 - e0y * (x0 - vbx),
            e1 = row1 - e1y * (x0 - vcx),
            e2 = row2 - e2y * (x0 - vax);
        var z = (za * e0 + zb * e1 + zc * e2) * inverseArea,
            uz = (uza * e0 + uzb * e1 + uzc * e2) * inverseArea,
            vz = (vza * e0 + vzb * e1 + vzc * e2) * inverseArea;
        final fu = uz * uScale, fv = vz * vScale;
        final fixed = affine && fu.abs() < 1 << 40 && fv.abs() < 1 << 40;
        var su = fixed ? fu.toInt() : 0, sv = fixed ? fv.toInt() : 0;
        for (var x = rowLeft;
            x < rowRight;
            x++,
            e0 -= e0y,
            e1 -= e1y,
            e2 -= e2y,
            z += dz,
            uz += duz,
            vz += dvz,
            su += dsu,
            sv += dsv) {
          if (e0 < 0 ||
              e1 < 0 ||
              e2 < 0 ||
              (e0 == 0 && !tl0) ||
              (e1 == 0 && !tl1) ||
              (e2 == 0 && !tl2)) {
            continue;
          }
          if (!z.isFinite) {
            throw const DcUnsupported('CORE nonfinite interpolated depth');
          }
          final index = y * 32 + x, previous = depthBuffer[index];
          // Compare modes are masks of less (1), equal (2) and greater (4).
          final pass = compare &
                  (z < previous
                      ? 1
                      : z == previous
                          ? 2
                          : 4) !=
              0;
          // A zero depth has no perspective; such fragments are dropped.
          if (!pass || z == 0) continue;
          final lanes = fixed ? texture.sampleLanesFixed(su, sv) : -1;
          int shaded;
          if (lanes >= 0 && gray) {
            shaded = DcGpuTexture.shadeGrayLanes(
                lanes, quickGray, quickOffset, ignoredAlpha);
          } else {
            final texel = lanes >= 0
                ? DcGpuTexture.packLanes(lanes)
                : texture.sampleBilinear(uz * (1 / z), vz * (1 / z));
            shaded = gray
                ? DcGpuTexture.shadeGray(
                    texel, quickGray, quickOffset, ignoredAlpha)
                : DcGpuTexture.shade(quickColor, texel, quickOffset, tsp);
          }
          if (quickFog) {
            shaded =
                fog.apply(shaded, z, quickOffset, tsp, hasOffset: fogOffset);
          }
          if (replace) {
            colorBuffer[index] = shaded;
          } else {
            _composite(index, shaded, tsp);
          }
          if (writeDepth) depthBuffer[index] = z;
        }
        continue;
      }
      for (var x = rowLeft; x < rowRight; x++) {
        final px = originX + x + offset;
        final e0 = row0 - e0y * (px - b.x),
            e1 = row1 - e1y * (px - c.x),
            e2 = row2 - e2y * (px - a.x);
        if (e0 < 0 ||
            e1 < 0 ||
            e2 < 0 ||
            (e0 == 0 && !tl0) ||
            (e1 == 0 && !tl1) ||
            (e2 == 0 && !tl2)) {
          continue;
        }
        final ia = plane == null ? e0 * inverseArea : ax * px + ay * py + a0;
        final ib = plane == null ? e1 * inverseArea : bx * px + by * py + b0;
        final ic = plane == null ? e2 * inverseArea : cx * px + cy * py + c0;
        final ispDepth = za * ia + zb * ib + zc * ic;
        final z = background ? backgroundZ : ispDepth;
        if (!z.isFinite) {
          throw const DcUnsupported('CORE nonfinite interpolated depth');
        }
        final index = y * 32 + x, previous = _depth[index];
        if (_materialArea >= 0 && _shadowMask[index] != _materialArea) continue;
        final pass = background ||
            (_sortMode != 0
                ? z >= previous
                : switch (isp >> 29) {
                    0 => false,
                    1 => z < previous,
                    2 => z == previous,
                    3 => z <= previous,
                    4 => z > previous,
                    5 => z != previous,
                    6 => z >= previous,
                    _ => true,
                  });
        if (!pass) continue;
        if (_sortMode == 1) {
          final last = _lastDepth[index], lastOrder = _lastOrder[index];
          if (z < last || (z == last && order <= lastOrder)) continue;
          final current = _candidates[index];
          if (current != null &&
              (z > current.depth ||
                  (z == current.depth && order >= current.order))) {
            continue;
          }
        } else if (_sortMode == 2) {
          final current = _candidates[index];
          if (current != null && z < current.depth) continue;
        } else if (_visibility != 0) {
          final hidden = _visibility == 1 ||
              (background
                  // A replacing opaque fragment hides the primary background.
                  ? _firstShaded[index] >= 0 && tsp & 0x01000000 == 0
                  : order < _firstShaded[index]);
          if (!hidden) {
            _shownFragments++;
          } else if (background) {
            if (texture != null) _hiddenFragments++;
            continue;
          } else {
            if (_visibility == 2 && texture != null) _hiddenFragments++;
            // ONE/ZERO blending into the primary buffer hides earlier fragments.
            if (tsp & 0xff000000 == 0x20000000) _firstShaded[index] = order;
            if (isp & 0x04000000 == 0) _depth[index] = z;
            continue;
          }
        }
        var color = flatColor;
        if (!flat) {
          if (quick && ispDepth != 0) {
            final inverse = 1 / ispDepth;
            final pa = ia * za * inverse,
                pb = ib * zb * inverse,
                pc = ic * zc * inverse;
            final color = (sameColors
                    ? sc.color
                    : _gouraud(sa.color, sb.color, sc.color, pa, pb, pc)) |
                opaqueAlpha;
            final off = sameOffsets
                ? sc.offsetColor
                : _gouraud(
                    sa.offsetColor, sb.offsetColor, sc.offsetColor, pa, pb, pc);
            final texel = texture.sampleBilinear(
                (uza * ia + uzb * ib + uzc * ic) * inverse,
                (vza * ia + vzb * ib + vzc * ic) * inverse);
            var shaded = DcGpuTexture.shade(color, texel, off, tsp);
            if (quickFog) {
              shaded = fog.apply(shaded, ispDepth, off, tsp,
                  hasOffset: isp & 0x01000000 != 0);
            }
            if (replace) {
              _colors[index] = shaded;
            } else {
              _composite(index, shaded, tsp);
            }
            if (isp & 0x04000000 == 0) _depth[index] = z;
            continue;
          }
          // HALF_OFFSET independently selects ISP coverage/depth and TSP shading.
          final sx = originX + x + pixelOffset, sy = originY + y + pixelOffset;
          final wa = samePosition ? ia : ax * sx + ay * sy + a0;
          final wb = samePosition ? ib : bx * sx + by * sy + b0;
          final wc = samePosition ? ic : cx * sx + cy * sy + c0;
          final shadeDepth =
              samePosition ? ispDepth : za * wa + zb * wb + zc * wc;
          if (!shadeDepth.isFinite) {
            throw const DcUnsupported('CORE nonfinite shading depth');
          }
          color = 0;
          if (tsp & 0x02000000 == 0) {
            int off;
            if (gouraud) {
              if (shadeDepth == 0) {
                throw const DcUnsupported(
                    'CORE shading perspective denominator is zero');
              }
              final inverseDepth = 1 / shadeDepth;
              final pa = wa * za * inverseDepth,
                  pb = wb * zb * inverseDepth,
                  pc = wc * zc * inverseDepth;
              color = _gouraud(sa.color, sb.color, sc.color, pa, pb, pc);
              off = _gouraud(
                  sa.offsetColor, sb.offsetColor, sc.offsetColor, pa, pb, pc);
            } else {
              color = sc.color;
              off = sc.offsetColor;
            }
            if (_shadowObject && shadowIntensity && _shadowMask[index] != 0) {
              if (_sortMode == 2 && tsp & 0x100000 != 0) {
                throw const DcUnsupported(
                    'CORE punch-through shadow alpha needs validation');
              }
              color = _shadowColor(color);
              off = _shadowColor(off);
            }
            if (tsp & 0x100000 == 0) color |= 0xff000000;
            var footprint = 1.0;
            if (texture != null) {
              final tx = originX + x + texOffset, ty = originY + y + texOffset;
              final ta = sameTexture ? wa : ax * tx + ay * ty + a0,
                  tb = sameTexture ? wb : bx * tx + by * ty + b0,
                  tc = sameTexture ? wc : cx * tx + cy * ty + c0;
              final denominator = za * ta + zb * tb + zc * tc;
              if (denominator == 0) {
                throw const DcUnsupported(
                    'CORE perspective UV denominator is zero');
              }
              final inverse = 1 / denominator;
              final u = (uza * ta + uzb * tb + uzc * tc) * inverse;
              final v = (vza * ta + vzb * tb + vzc * tc) * inverse;
              if (mipNumerators != null) {
                final square = inverse * inverse;
                footprint = texture.footprint(
                    mipNumerators[0] * square,
                    mipNumerators[1] * square,
                    mipNumerators[2] * square,
                    mipNumerators[3] * square);
              }
              List<(double, double)>? extraSamples;
              if (texture.superSample) {
                (double, double) coordinate(double dx, double dy) {
                  final qx = tx + dx, qy = ty + dy;
                  final aa = ax * qx + ay * qy + a0;
                  final bb = bx * qx + by * qy + b0;
                  final cc = cx * qx + cy * qy + c0;
                  final divisor = za * aa + zb * bb + zc * cc;
                  if (divisor == 0) {
                    throw const DcUnsupported(
                        'CORE supersample perspective denominator is zero');
                  }
                  return (
                    (uza * aa + uzb * bb + uzc * cc) / divisor,
                    (vza * aa + vzb * bb + vzc * cc) / divisor
                  );
                }

                extraSamples = [
                  coordinate(0.5, 0),
                  coordinate(0, 0.5),
                  coordinate(0.5, 0.5)
                ];
              }
              final texel = texture.plainBilinear
                  ? texture.sampleBilinear(u, v)
                  : texture.sample(u, v,
                      footprint: footprint,
                      extraSamples: extraSamples,
                      bumpParameters: texture.format == 4 ? off : null);
              // K1K2K3Q replaces Offset Color; its RGB bytes are not additive color.
              color = DcGpuTexture.shade(
                  color, texel, texture.format == 4 ? 0 : off, tsp);
            }
            color = fog.apply(
                color, background ? backgroundZ : shadeDepth, off, tsp,
                hasOffset: texture != null && isp & 0x01000000 != 0);
            if (texture?.trilinear == true) {
              color = texture!.applyPassWeight(color, footprint);
            }
          }
        }
        if (background) {
          _storeColor(index, color, tsp);
          continue;
        }
        if (_sortMode == 2 &&
            _sourceColor(index, color, tsp) >> 24 < alphaReference) {
          continue;
        }
        if (_sortMode == 3) {
          _addFragment(index, z, color, tsp, isp & 0x04000000 == 0, order);
        } else if (_sortMode != 0) {
          _candidates[index] =
              _Fragment(z, color, tsp, isp & 0x04000000 == 0, order);
        } else {
          _composite(index, color, tsp);
          if (isp & 0x04000000 == 0) _depth[index] = z;
        }
      }
    }
  }

  /// Perspective-weighted color channels, rounded and saturated per byte.
  static int _gouraud(int ca, int cb, int cc, double pa, double pb, double pc) {
    // Equal vertex colors interpolate to themselves.
    if (ca == cb && cb == cc) return ca;
    return roundByte((ca & 255) * pa + (cb & 255) * pb + (cc & 255) * pc) |
        (roundByte(((ca >> 8) & 255) * pa +
                ((cb >> 8) & 255) * pb +
                ((cc >> 8) & 255) * pc) <<
            8) |
        (roundByte(((ca >> 16) & 255) * pa +
                ((cb >> 16) & 255) * pb +
                ((cc >> 16) & 255) * pc) <<
            16) |
        (roundByte((ca >> 24) * pa + (cb >> 24) * pb + (cc >> 24) * pc) << 24);
  }

  int _shadowColor(int color) {
    final scale = read(0x74) & 255;
    var result = 0;
    for (var shift = 0; shift < 32; shift += 8) {
      result |= ((((color >> shift) & 255) * scale) >> 8) << shift;
    }
    return result & 0xffffffff;
  }

  int _sourceColor(int index, int color, int tsp) {
    if (tsp & 0x02000000 != 0) {
      if (_secondaryValid[index] == 0) {
        throw const DcUnsupported(
            'CORE secondary source pixel is uninitialized');
      }
      return _secondary[index];
    }
    return color;
  }

  void _composite(int index, int color, int tsp) {
    color = _sourceColor(index, color, tsp);
    final destinationSecondary = tsp & 0x01000000 != 0;
    var destination = _colors[index];
    if (destinationSecondary) {
      final sourceFactor = (tsp >> 29) & 7;
      final destinationFactor = (tsp >> 26) & 7;
      final needsDestination =
          destinationFactor != 0 || (0xcc >> sourceFactor) & 1 != 0;
      if (needsDestination && _secondaryValid[index] == 0) {
        throw const DcUnsupported(
            'CORE secondary destination pixel is uninitialized');
      }
      destination = _secondaryValid[index] != 0 ? _secondary[index] : 0;
    }
    final result = _blend(color, destination, tsp);
    _storeColor(index, result, tsp);
  }

  void _storeColor(int index, int color, int tsp) {
    if (tsp & 0x01000000 != 0) {
      _secondary[index] = color;
      _secondaryValid[index] = 1;
    } else {
      _colors[index] = color;
    }
  }

  static int _factor(
          int instruction, int other, int sourceAlpha, int destinationAlpha) =>
      switch (instruction) {
        0 => 0,
        1 => 255,
        2 => other,
        3 => 255 - other,
        4 => sourceAlpha,
        5 => 255 - sourceAlpha,
        6 => destinationAlpha,
        _ => 255 - destinationAlpha,
      };

  static int _blendChannel(int src, int dst, int sourceInstruction,
      int destinationInstruction, int sourceAlpha, int destinationAlpha) {
    final sum = div255(src *
            _factor(sourceInstruction, dst, sourceAlpha, destinationAlpha) +
        dst *
            _factor(
                destinationInstruction, src, sourceAlpha, destinationAlpha) +
        127);
    return sum > 255 ? 255 : sum;
  }

  static int _blend(int source, int destination, int tsp) {
    final sourceInstruction = (tsp >> 29) & 7;
    final destinationInstruction = (tsp >> 26) & 7;
    // ONE/ZERO: (s * 255 + 127) ~/ 255 is s for every channel.
    if (sourceInstruction == 1 && destinationInstruction == 0) {
      return source & 0xffffffff;
    }
    final sa = (source >> 24) & 255, da = (destination >> 24) & 255;
    if (sourceInstruction & 6 != 2 && destinationInstruction & 6 != 2) {
      // Alpha and constant factors are the same for every channel; with a
      // factor sum up to 255 no channel saturates and 16-bit lanes suffice.
      final sf = _factor(sourceInstruction, 0, sa, da),
          df = _factor(destinationInstruction, 0, sa, da);
      if (sf + df <= 255) {
        const lanes = 0x00ff00ff00ff00ff;
        final x = DcGpuTexture.toLanes(source) * sf +
            DcGpuTexture.toLanes(destination) * df +
            0x007f007f007f007f;
        // div255 of each lane, exact below 2^16.
        return DcGpuTexture.packLanes(
            ((x + ((x >>> 8) & lanes) + 0x0001000100010001) >>> 8) & lanes);
      }
    }
    return _blendChannel(source & 255, destination & 255, sourceInstruction,
            destinationInstruction, sa, da) |
        (_blendChannel((source >> 8) & 255, (destination >> 8) & 255,
                sourceInstruction, destinationInstruction, sa, da) <<
            8) |
        (_blendChannel((source >> 16) & 255, (destination >> 16) & 255,
                sourceInstruction, destinationInstruction, sa, da) <<
            16) |
        (_blendChannel(
                sa, da, sourceInstruction, destinationInstruction, sa, da) <<
            24);
  }

  bool _flushVerticalScale({bool finalSource = true}) {
    // Framebuffer output stages the scene; strip output retains only required source rows.
    // Hardware line-buffer latency and channel rounding remain unmeasured.
    final factor = read(0xf4) & 0xffff;
    // Type B stores alternating filtered source lines in a half-height frame.
    // Field Select has no effect when type-B interlacing is disabled.
    final fieldOffset = read(0xf4) & 0x60000 == 0x60000 ? 1024 : 0;
    var minX = 2048, minY = 2048, maxX = -1, maxY = -1;
    for (final key in _scalerTiles.keys) {
      final x = (key & 63) * 32, y = (key >> 6) * 32;
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (x + 31 > maxX) maxX = x + 31;
      if (y + 31 > maxY) maxY = y + 31;
    }
    final xClip = read(0x68), yClip = read(0x6c);
    final xStep = read(0xf4) & 0x10000 != 0 ? 2 : 1;
    final sourceMinX = (xClip & 2047) * xStep;
    final sourceMaxX = ((xClip >> 16) + 1) * xStep - 1;
    if (minX < sourceMinX) minX = sourceMinX;
    if (maxX > sourceMaxX) maxX = sourceMaxX;
    if (minX > maxX || minY > maxY) {
      _scalerTiles.clear();
      _stripScaleRow = -1;
      return true;
    }
    var first = (minY * 1024 + factor - 1) ~/ factor;
    var end = (maxY + 1) * 1024 ~/ factor;
    if (first < (yClip & 1023)) first = yClip & 1023;
    if (end > (yClip >> 16) + 1) end = (yClip >> 16) + 1;
    int source(int x, int y) {
      y = y.clamp(minY, maxY);
      final tile = _scalerTiles[(y ~/ 32) * 64 + x ~/ 32];
      if (tile == null) {
        throw const DcUnsupported(
            'CORE vertical scaler source has missing tiles');
      }
      return tile[(y & 31) * 32 + (x & 31)];
    }

    final outer = read(0x118) & 255, center = (read(0x118) >> 8) & 255;
    int filtered(int x, int y) {
      final b = source(x, y);
      if (factor <= 1024) return b;
      final a = source(x, y - 1), c = source(x, y + 1);
      var result = 0;
      for (var shift = 0; shift < 32; shift += 8) {
        final value = ((((a >> shift) & 255) * outer +
                    ((b >> shift) & 255) * center +
                    ((c >> shift) & 255) * outer) ~/
                256)
            .clamp(0, 255);
        result |= value << shift;
      }
      return result;
    }

    final retained = Uint32List.fromList(_colors);
    try {
      final firstTile = _stripScaleRow < 0
          ? first ~/ 32
          : (first ~/ 32 > _stripScaleRow ? first ~/ 32 : _stripScaleRow);
      for (var ty = firstTile; ty * 32 < end; ty++) {
        if (!finalSource) {
          final lastRow = ((ty + 1) * 32 - 1).clamp(0, yClip >> 16);
          final lastPosition = lastRow * factor + fieldOffset;
          final needed = lastPosition ~/ 1024 +
              (lastPosition & 1023 != 0 ? 1 : 0) +
              (factor > 1024 ? 1 : 0);
          if (lastRow >= end || needed > maxY) break;
        }
        if (_stripLines != 0 && ty * 32 ~/ _stripLines > _stripConsumed + 2) {
          _stripScaleRow = ty;
          _stripWaiting = true;
          return false;
        }
        for (var tx = minX ~/ 32; tx <= maxX ~/ 32; tx++) {
          _colors.setRange(0, 1024, _zeroWords);
          for (var y = 0; y < 32; y++) {
            final py = ty * 32 + y;
            if (py < first || py >= end) continue;
            final position = py * factor + fieldOffset;
            final row = position ~/ 1024, fraction = position & 1023;
            for (var x = 0; x < 32; x++) {
              final px = tx * 32 + x;
              if (px < minX || px > maxX) continue;
              final a = filtered(px, row);
              if (fraction == 0) {
                _colors[y * 32 + x] = a;
                continue;
              }
              final b = filtered(px, row + 1);
              var color = 0;
              for (var shift = 0; shift < 32; shift += 8) {
                color |= (((((a >> shift) & 255) * (1024 - fraction) +
                            ((b >> shift) & 255) * fraction) ~/
                        1024)) <<
                    shift;
              }
              _colors[y * 32 + x] = color;
            }
          }
          _writeTile(tx * 32, ty * 32, scaledFirst: first, scaledEnd: end);
        }
        if (_stripLines != 0 &&
            ((finalSource && (ty + 1) * 32 >= end) ||
                (ty + 1) * 32 > (yClip >> 16) ||
                (ty + 1) * 32 % _stripLines == 0)) {
          _stripProduced = ty * 32 ~/ _stripLines;
        }
        if (_stripLines != 0) _stripScaleRow = ty + 1;
      }
    } finally {
      _colors.setAll(0, retained);
      if (!finalSource && _stripScaleRow >= 0) {
        final nextPosition = _stripScaleRow * 32 * factor + fieldOffset;
        final firstNeeded = nextPosition ~/ 1024 - (factor > 1024 ? 1 : 0);
        _scalerTiles
            .removeWhere((key, _) => (key >> 6) * 32 + 31 < firstNeeded);
      }
    }
    if (!finalSource) return true;
    _scalerTiles.clear();
    _stripScaleRow = -1;
    return true;
  }

  void _writeTile(int originX, int originY,
      {int? scaledFirst, int? scaledEnd}) {
    if (scaledFirst == null && read(0xf4) & 0xffff != 1024) {
      _scalerTiles[(originY ~/ 32) * 64 + originX ~/ 32] =
          Uint32List.fromList(_colors);
      return;
    }
    final xClip = read(0x68);
    final yClip = scaledFirst == null
        ? read(0x6c)
        : scaledFirst | ((scaledEnd! - 1) << 16);
    final mode = read(0x48) & 7, kval = (read(0x48) >> 8) & 255;
    final threshold = (read(0x48) >> 16) & 255;
    final dither = mode <= 3 && read(0x48) & 8 != 0;
    final bytes = mode <= 3
        ? 2
        : mode == 4
            ? 3
            : 4;
    final stride = read(0x4c) * 8;
    final halfWidth = read(0xf4) & 0x10000 != 0;
    if (stride == 0) throw const DcUnsupported('CORE zero framebuffer stride');
    final ranks = dither
        ? const [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
        : null;
    final rgbShift = mode == 2 ? 4 : 3, greenShift = mode == 1 ? 2 : rgbShift;
    final step = halfWidth ? 2 : 1;
    for (var y = 0; y < 32; y++) {
      final py = originY + y;
      if (py < (yClip & 1023) || py > (yClip >> 16)) continue;
      final start =
          read(_stripLines != 0 && (py ~/ _stripLines).isOdd ? 0x64 : 0x60);
      final memoryRow = _stripLines == 0 ? py : py % _stripLines;
      final rowAddress = (start & 0x7fffff) + memoryRow * stride;
      final interleaved = start & 0x1000000 != 0;
      final first = rowAddress + originX * 2;
      if (bytes == 2 &&
          !halfWidth &&
          !interleaved &&
          originX >= (xClip & 2047) &&
          originX + 31 <= (xClip >> 16) &&
          first >= 0 &&
          first + 64 <= memory.length) {
        _writeRow16(first, y, py, mode, kval, threshold,
            ranks == null ? null : (py & 3) * 4, rgbShift, greenShift);
        continue;
      }
      // One stamp per run of bytes on the same page keeps the newest stamp.
      var markedPage = -1;
      for (var x = 0; x < 32; x += step) {
        final px = halfWidth ? (originX + x) ~/ 2 : originX + x;
        if (px < (xClip & 2047) || px > (xClip >> 16)) continue;
        var color = _colors[y * 32 + x];
        if (halfWidth) {
          // System Architecture 3.4.11.1: average adjacent accumulation pixels.
          // Half-integer channels truncate here; physical rounding is unverified.
          final other = _colors[y * 32 + x + 1];
          var average = 0;
          for (var shift = 0; shift < 32; shift += 8) {
            average |=
                ((((color >> shift) & 255) + ((other >> shift) & 255)) ~/ 2) <<
                    shift;
          }
          color = average & 0xffffffff;
        }
        final a = color >> 24;
        var r = (color >> 16) & 255, g = (color >> 8) & 255, b = color & 255;
        if (ranks != null) {
          // Provisional ordered pattern; the manual specifies enable/formats, not the matrix.
          final rank = ranks[(py & 3) * 4 + (px & 3)];
          r = (r + ((rank << rgbShift) >> 4)).clamp(0, 255);
          b = (b + ((rank << rgbShift) >> 4)).clamp(0, 255);
          g = (g + ((rank << greenShift) >> 4)).clamp(0, 255);
        }
        final value = switch (mode) {
          0 =>
            ((kval & 128) << 8) | ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3),
          1 => ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3),
          2 => ((a >> 4) << 12) | ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4),
          3 => ((a >= threshold ? 1 : 0) << 15) |
              ((r >> 3) << 10) |
              ((g >> 3) << 5) |
              (b >> 3),
          5 => (kval << 24) | (color & 0xffffff),
          _ => color,
        };
        final address = rowAddress + px * bytes;
        if (address < 0 || address + bytes > memory.length) {
          throw const DcUnsupported(
              'CORE framebuffer write outside retail VRAM');
        }
        if ((address & 3) + bytes <= 4) {
          // Within one 4-byte group the bytes stay consecutive and on one page.
          final offset = interleaved
              ? (address & 3) |
                  ((address >> 1) & 0x3ffffc) |
                  ((address & 4) << 20)
              : address;
          if (offset >> 12 != markedPage) {
            markedPage = offset >> 12;
            _pages.mark(offset);
          }
          memory[offset] = value & 255;
          memory[offset + 1] = (value >> 8) & 255;
          if (bytes == 4) {
            memory[offset + 2] = (value >> 16) & 255;
            memory[offset + 3] = (value >> 24) & 255;
          } else if (bytes == 3) {
            memory[offset + 2] = (value >> 16) & 255;
          }
          continue;
        }
        for (var i = 0; i < bytes; i++) {
          final byte = address + i;
          final offset = interleaved
              ? (byte & 3) | ((byte >> 1) & 0x3ffffc) | ((byte & 4) << 20)
              : byte;
          if (offset >> 12 != markedPage) {
            markedPage = offset >> 12;
            _pages.mark(offset);
          }
          memory[offset] = (value >> (8 * i)) & 255;
        }
      }
    }
  }
}

extension on DcGpuRender {
  /// One unclipped tile row of 16-bit pixels in linear VRAM; the same
  /// conversion as the general [DcGpuRender._writeTile] loop.
  @pragma('vm:prefer-inline')
  static int _pack565(int color, int add) {
    var lanes =
        (((color & 0xff0000) << 4) | ((color & 0xff00) << 2) | (color & 0xff)) +
            add;
    lanes |= ((lanes >> 8) & 0x100401) * 255;
    return ((lanes >> 12) & 0xf800) |
        ((lanes >> 7) & 0x7e0) |
        ((lanes >> 3) & 0x1f);
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void _writeRow16(int first, int y, int py, int mode, int kval, int threshold,
      int? rankRow, int rgbShift, int greenShift) {
    const ranks = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5];
    final colors = _colors, words = _vramWords;
    _pages.mark(first);
    _pages.mark(first + 63);
    final row = y * 32;
    if (mode == 1 && first & 1 == 0) {
      // R, G and B in 10-bit lanes: one add applies the dither, and the
      // carry out of each lane saturates it.
      var a0 = 0, a1 = 0, a2 = 0, a3 = 0;
      if (rankRow != null) {
        int lanes(int rank) {
          final rgb = (rank << 3) >> 4, green = (rank << 2) >> 4;
          return (rgb << 20) | (green << 10) | rgb;
        }

        a0 = lanes(ranks[rankRow]);
        a1 = lanes(ranks[rankRow + 1]);
        a2 = lanes(ranks[rankRow + 2]);
        a3 = lanes(ranks[rankRow + 3]);
      }
      final halves = _vramHalves;
      final at = first >> 1;
      for (var x = 0; x < 32; x += 4) {
        halves[at + x] = _pack565(colors[row + x], a0);
        halves[at + x + 1] = _pack565(colors[row + x + 1], a1);
        halves[at + x + 2] = _pack565(colors[row + x + 2], a2);
        halves[at + x + 3] = _pack565(colors[row + x + 3], a3);
      }
      return;
    }
    for (var x = 0; x < 32; x++) {
      final color = colors[row + x];
      var r = (color >> 16) & 255, g = (color >> 8) & 255, b = color & 255;
      if (rankRow != null) {
        final rank = ranks[rankRow + (x & 3)];
        final rgb = (rank << rgbShift) >> 4, green = (rank << greenShift) >> 4;
        r += rgb;
        b += rgb;
        g += green;
        if (r > 255) r = 255;
        if (g > 255) g = 255;
        if (b > 255) b = 255;
      }
      final value = switch (mode) {
        0 =>
          ((kval & 128) << 8) | ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3),
        1 => ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3),
        2 =>
          ((color >> 28) << 12) | ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4),
        _ => ((color >> 24 >= threshold ? 1 : 0) << 15) |
            ((r >> 3) << 10) |
            ((g >> 3) << 5) |
            (b >> 3),
      };
      words.setUint16(first + x * 2, value, Endian.little);
    }
  }
}

class _Vertex {
  const _Vertex(this.x, this.y, this.z, this.color,
      {this.u = 0, this.v = 0, this.offsetColor = 0});
  final double x, y, z, u, v;
  final int color, offsetColor;
}

class _Fragment {
  const _Fragment(
      this.depth, this.color, this.tsp, this.writeDepth, this.order);
  final double depth;
  final int color, tsp, order;
  final bool writeDepth;
}
