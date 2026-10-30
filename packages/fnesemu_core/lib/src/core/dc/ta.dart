import 'dart:math' as math;
import 'dart:typed_data';

import '../../state.dart';
import '../../util/uint8list.dart';
import 'fault.dart';

/// Functional HOLLY2 parameter conversion and object lists, System Architecture §3.7.
/// Input and VRAM writes complete synchronously; FIFO and cache timing are pending.
class DcTa {
  DcTa(this.memory, {required this.onNormal, required this.onError});
  final Uint8List memory;
  final void Function(int) onNormal, onError;
  int objectBase = 0, parameterBase = 0, objectLimit = 0, parameterLimit = 0;
  int nextObject = 0, currentParameter = 0, globalClip = 0, allocation = 0;
  int nextObjectInitial = 0;
  int _activeAllocation = 0;
  int _width = 1, _height = 1, _list = -1, _ended = 0;
  int _pcw = 0, _isp = 0, _tsp = 0, _texture = 0, _tsp1 = 0, _texture1 = 0;
  int _stripLength = 1, _clipMode = 0, _triangle = 0;
  bool _sprite = false, _modifier = false;
  int _spriteColor = 0, _spriteOffset = 0;
  List<double>? _face, _faceOffset, _face1;
  List<int>? _pendingPacket;
  List<int> _clip = [0, 0, 39, 14];
  final _vertices = <List<int>>[];
  final _blocks = <List<_Block>>[];
  bool _initialized = false, _header = false;
  final _float = ByteData(4);

  void saveState(StateWriter writer) {
    writer.section('dc.gpu.ta');
    writer.int64(memory.length);
    writer.ints([
      objectBase,
      parameterBase,
      objectLimit,
      parameterLimit,
      nextObject,
      currentParameter,
      globalClip,
      allocation,
      nextObjectInitial,
      _activeAllocation,
      _width,
      _height,
      _list,
      _ended,
      _pcw,
      _isp,
      _tsp,
      _texture,
      _tsp1,
      _texture1,
      _stripLength,
      _clipMode,
      _triangle,
      _spriteColor,
      _spriteOffset
    ]);
    for (final flag in [_sprite, _modifier, _initialized, _header]) {
      writer.boolean(flag);
    }
    for (final face in [_face, _faceOffset, _face1]) {
      writer.boolean(face != null);
      if (face != null) writer.floats(face);
    }
    writer.boolean(_pendingPacket != null);
    if (_pendingPacket != null) writer.ints(_pendingPacket!);
    writer.ints(_clip);
    writer.int32(_vertices.length);
    for (final vertex in _vertices) {
      writer.ints(vertex);
    }
    writer.int32(_blocks.length);
    for (final list in _blocks) {
      writer.int32(list.length);
      for (final block in list) {
        writer.ints([block.address, block.words, block.used]);
      }
    }
  }

  void loadState(StateReader reader) {
    reader.section('dc.gpu.ta');
    final memorySize = reader.int64(), v = reader.ints();
    final flags = [for (var i = 0; i < 4; i++) reader.boolean()];
    final faces = [
      for (var i = 0; i < 3; i++) reader.boolean() ? reader.floats() : null
    ];
    final packet = reader.boolean() ? reader.ints() : null;
    final clip = reader.ints();
    bool words(List<int> values) =>
        values.every((value) => value >= 0 && value <= 0xffffffff);
    if (memorySize != memory.length ||
        v.length != 25 ||
        [
          for (var i = 0; i < v.length; i++)
            if (i != 4 && i != 12 && i != 22) v[i]
        ].any((value) => value < 0 || value > 0xffffffff) ||
        v[4] < -128 ||
        v[4] > 0xffffffff ||
        v[10] < 1 ||
        v[10] > 64 ||
        v[11] < 1 ||
        v[11] > 16 ||
        v[12] < -1 ||
        v[12] > 4 ||
        v[13] & ~31 != 0 ||
        ![1, 2, 4, 6].contains(v[20]) ||
        v[21] > 3 ||
        v[22] < 0 ||
        faces.any((face) =>
            face != null &&
            (face.length != 4 ||
                face.any(
                    (value) => !value.isFinite || value < 0 || value > 1))) ||
        (packet != null && (packet.length != 8 || !words(packet))) ||
        clip.length != 4 ||
        clip.any((value) => value < 0) ||
        clip[0] > 63 ||
        clip[1] > 15 ||
        clip[2] > 63 ||
        clip[3] > 15) {
      throw const StateMismatch('TA registers or input state');
    }
    final vertexCount = reader.int32();
    if (vertexCount < 0 || vertexCount > memory.length ~/ 4) {
      throw const StateMismatch('TA vertex layout');
    }
    final vertices = <List<int>>[];
    for (var i = 0; i < vertexCount; i++) {
      final vertex = reader.ints();
      if (vertex.length < 3 || vertex.length > 11 || !words(vertex)) {
        throw const StateMismatch('TA vertex state');
      }
      vertices.add(vertex);
    }
    final listCount = reader.int32();
    if (listCount < 0 || listCount > 5) {
      throw const StateMismatch('TA list layout');
    }
    final blocks = <List<_Block>>[];
    for (var i = 0; i < listCount; i++) {
      final count = reader.int32();
      if (count < 0 || count > 1024) {
        throw const StateMismatch('TA tile layout');
      }
      final list = <_Block>[];
      for (var tile = 0; tile < count; tile++) {
        final fields = reader.ints();
        if (fields.length != 3 ||
            fields[0] < 0 ||
            fields[0] & 3 != 0 ||
            ![8, 16, 32].contains(fields[1]) ||
            fields[0] + fields[1] * 4 > memory.length ||
            fields[2] < 0 ||
            fields[2] >= fields[1]) {
          throw const StateMismatch('TA object-list cursor');
        }
        list.add(_Block(fields[0], fields[1])..used = fields[2]);
      }
      blocks.add(list);
    }
    objectBase = v[0];
    parameterBase = v[1];
    objectLimit = v[2];
    parameterLimit = v[3];
    nextObject = v[4];
    currentParameter = v[5];
    globalClip = v[6];
    allocation = v[7];
    nextObjectInitial = v[8];
    _activeAllocation = v[9];
    _width = v[10];
    _height = v[11];
    _list = v[12];
    _ended = v[13];
    _pcw = v[14];
    _isp = v[15];
    _tsp = v[16];
    _texture = v[17];
    _tsp1 = v[18];
    _texture1 = v[19];
    _stripLength = v[20];
    _clipMode = v[21];
    _triangle = v[22];
    _spriteColor = v[23];
    _spriteOffset = v[24];
    _sprite = flags[0];
    _modifier = flags[1];
    _initialized = flags[2];
    _header = flags[3];
    _face = faces[0];
    _faceOffset = faces[1];
    _face1 = faces[2];
    _pendingPacket = packet;
    _clip = clip;
    _vertices
      ..clear()
      ..addAll(vertices);
    _blocks
      ..clear()
      ..addAll(blocks);
  }

  double _value(int bits) {
    _float.setUint32(0, bits, Endian.little);
    return _float.getFloat32(0, Endian.little);
  }

  Never _illegal(String reason) {
    onError(1 << 4);
    throw DcUnsupported('TA $reason');
  }

  void reset({bool registers = true}) {
    if (registers) {
      objectBase = parameterBase = objectLimit = parameterLimit = 0;
      globalClip = allocation = nextObjectInitial = 0;
    }
    nextObject = currentParameter = 0;
    _activeAllocation = 0;
    _initialized = _header = _sprite = _modifier = false;
    _spriteColor = _spriteOffset = 0;
    _list = -1;
    _ended = _pcw = _isp = _tsp = _texture = _triangle = _clipMode = 0;
    _tsp1 = _texture1 = 0;
    _stripLength = 1;
    _face = _faceOffset = _face1 = null;
    _pendingPacket = null;
    _vertices.clear();
    _blocks.clear();
    _clip = [0, 0, 39, 14];
  }

  int read(int offset) => switch (offset) {
        0x124 => objectBase,
        0x128 => parameterBase,
        0x12c => objectLimit,
        0x130 => parameterLimit,
        0x134 => nextObject,
        0x138 => currentParameter,
        0x13c => globalClip,
        0x140 => allocation,
        0x144 || 0x160 => 0,
        0x164 => nextObjectInitial,
        _ => throw DcUnsupported('unimplemented TA register: $offset'),
      };

  void write(int offset, int value) {
    switch (offset) {
      case 0x124:
        objectBase = value & 0xffffe0;
      case 0x128:
        parameterBase = value & 0xfffffc;
      case 0x12c:
        objectLimit = value & 0xffffe0;
      case 0x130:
        parameterLimit = value & 0xfffffc;
      case 0x134:
      case 0x138:
        return;
      case 0x13c:
        globalClip = value & 0xf003f;
      case 0x140:
        allocation = value & 0x133333;
      case 0x164:
        nextObjectInitial = value & 0xffffe0;
      case 0x144:
        if (value & 0x80000000 != 0) initialize();
      case 0x160:
        if (value & 0x80000000 != 0) initialize(continuation: true);
      default:
        throw DcUnsupported('unimplemented TA register: $offset');
    }
  }

  int _words(int list) {
    final code = (_activeAllocation >> (list * 4)) & 3;
    return code == 0 ? 0 : 4 << code;
  }

  void initialize({bool continuation = false}) {
    if (continuation && !_initialized) {
      _illegal('continuation before initialization');
    }
    if (_vertices.isNotEmpty || _pendingPacket != null) {
      _illegal('initialization interrupts an unfinished strip or packet');
    }
    _width = (globalClip & 63) + 1;
    _height = ((globalClip >> 16) & 15) + 1;
    // Bring-up accepts the full encoded clip field used by the retail BIOS.
    // This provisionally accepts values that the manual marks as prohibited.
    if (!continuation) {
      nextObject = nextObjectInitial;
      currentParameter = parameterBase;
      _face = _faceOffset = _face1 = null;
      _pendingPacket = null;
      _stripLength = 1;
      _clipMode = 0;
    }
    _activeAllocation = allocation;
    _blocks.clear();
    var address = objectBase;
    for (var list = 0; list < 5; list++) {
      final words = _words(list);
      final entries = <_Block>[];
      if (words != 0) {
        for (var tile = 0; tile < _width * _height; tile++) {
          _checkObject(address, words * 4);
          // Allocated lists must already be empty before any polygons arrive.
          memory.setUint32LE(address, 0xf0000000);
          entries.add(_Block(address, words));
          address += words * 4;
        }
      }
      _blocks.add(entries);
    }
    _initialized = true;
    _header = false;
    _list = -1;
    _ended = 0;
    _triangle = 0;
    _clip = [0, 0, 39, 14];
  }

  void _checkObject(int address, int length) {
    // OL_LIMIT identifies the final permitted 32-byte block, not its first byte only.
    if (address < 0 ||
        address + length > memory.length ||
        (_activeAllocation & 0x100000 == 0
            ? address + length > objectLimit + 32
            : address < objectLimit)) {
      onError(1 << 3);
      throw const DcUnsupported('TA object-list allocation overflow');
    }
  }

  void _selectList(int pcw) {
    if (_list >= 0) {
      return; // List type is sampled only at the first header/object set.
    }
    final list = (pcw >> 24) & 7;
    if (list > 4 || _ended & (1 << list) != 0) {
      _illegal('prohibited or repeated list');
    }
    _list = list;
  }

  void accept(Uint8List bytes) {
    if (bytes.length != 32) {
      throw const DcUnsupported('TA input requires a 32-byte burst');
    }
    if (!_initialized) _illegal('parameter before list initialization');
    var words = [for (var i = 0; i < 32; i += 4) bytes.getUint32LE(i)];
    if (_pendingPacket != null) {
      words = [..._pendingPacket!, ...words];
      _pendingPacket = null;
    } else {
      final type = words[0] >> 29;
      final list = _list >= 0 ? _list : (words[0] >> 24) & 7;
      final longGlobal = type == 4 &&
          list != 1 &&
          list != 3 &&
          ((words[0] >> 4) & 3) == 2 &&
          words[0] & 0x44 != 0;
      final longVertex = type == 7 &&
          _header &&
          _list >= 0 &&
          (_sprite ||
              _modifier ||
              (_pcw & 8 != 0 && (_pcw & 0x40 != 0 || ((_pcw >> 4) & 3) == 1)));
      if (longGlobal || longVertex) {
        _pendingPacket = words;
        return;
      }
    }
    final pcw = words[0], type = pcw >> 29;
    switch (type) {
      case 0:
        _endList();
      case 1:
        _clip = [words[4] & 63, words[5] & 15, words[6] & 63, words[7] & 15];
        if (_clip[0] > _clip[2] ||
            _clip[1] > _clip[3] ||
            _clip[2] > 39 ||
            _clip[3] > 14) {
          _illegal('invalid user clip');
        }
      case 2:
        if (_vertices.isNotEmpty) _illegal('object set interrupts a strip');
        _selectList(pcw);
        _register(words[1], words[4] & 63, words[5] & 15, words[6] & 63,
            words[7] & 15);
      case 4:
        _global(words);
      case 5:
        _global(words, sprite: true);
      case 7:
        _vertex(words);
      default:
        _illegal('unsupported parameter type $type');
    }
  }

  void _global(List<int> words, {bool sprite = false}) {
    if (_vertices.isNotEmpty) _illegal('global header interrupts a strip');
    _selectList(words[0]);
    _pcw = words[0];
    _modifier = _list == 1 || _list == 3;
    if (_modifier) {
      if (sprite || _pcw & 0x80 != 0) _illegal('reserved modifier format');
      final instruction = words[1] >> 29;
      if (instruction > 2 || ((_pcw & 0x40 != 0) != (instruction != 0))) {
        _illegal('modifier last flag and volume instruction disagree');
      }
      _sprite = false;
      _isp = words[1] & 0xf8000000;
      _tsp = _texture = 0;
      _group();
      _header = true;
      return;
    }
    final twoVolumes = _pcw & 0x40 != 0;
    if (twoVolumes && (sprite || _pcw & 0x80 == 0 || ((_pcw >> 4) & 3) == 1)) {
      _illegal('reserved two-volume format');
    }
    if (sprite && ((_pcw & 0x32) != 0 || (_pcw & 8 != 0 && _pcw & 1 == 0))) {
      _illegal('sprite requires packed flat color and 16-bit textured UV');
    }
    _sprite = sprite;
    _spriteColor = words[4];
    _spriteOffset = words[5];
    _group();
    final colorType = (_pcw >> 4) & 3;
    if (twoVolumes && colorType == 2) {
      _face = [for (var i = 8; i < 12; i++) _component(words[i])];
      _face1 = [for (var i = 12; i < 16; i++) _component(words[i])];
      _faceOffset = _face;
    } else if (colorType == 2) {
      final start = _pcw & 4 != 0 ? 8 : 4;
      _face = [for (var i = start; i < start + 4; i++) _component(words[i])];
      if (_pcw & 4 != 0) {
        _faceOffset = [for (var i = 12; i < 16; i++) _component(words[i])];
      }
    } else if (colorType == 3 &&
        (_face == null || (twoVolumes && _face1 == null))) {
      _illegal('intensity mode 2 has no preceding face color');
    }
    // Non-textured parameters force Offset to zero (System Architecture section 3.7.6.2).
    final flags = (_pcw & 15) & (_pcw & 8 != 0 ? 15 : 11);
    _isp = (words[1] & 0xfc3fffff) | (flags << 22);
    _tsp = words[2];
    _texture = words[3];
    _tsp1 = twoVolumes ? words[4] : 0;
    _texture1 = twoVolumes ? words[5] : 0;
    if (_pcw & 8 != 0 &&
        colorType >= 2 &&
        (((_texture >> 27) & 7) == 4 ||
            (twoVolumes && ((_texture1 >> 27) & 7) == 4))) {
      _illegal('bump mapping cannot use intensity color input');
    }
    _header = true;
    _triangle = 0;
  }

  void _group() {
    if (_pcw & 0x800000 != 0) {
      _stripLength = [1, 2, 4, 6][(_pcw >> 18) & 3];
      _clipMode = (_pcw >> 16) & 3;
      if (_clipMode == 1) _illegal('reserved user-clip mode');
    }
  }

  double _component(int word) {
    final value = _value(word);
    if (!value.isFinite) _illegal('nonfinite color');
    return value.clamp(0.0, 1.0);
  }

  void _vertex(List<int> words) {
    if (!_header || _list < 0) _illegal('vertex without a global parameter');
    if (_modifier) {
      _modifierVertex(words);
      return;
    }
    if (_sprite) {
      _spriteVertex(words);
      return;
    }
    for (var i = 1; i < 4; i++) {
      if (!_value(words[i]).isFinite) _illegal('nonfinite vertex coordinate');
    }
    if (_pcw & 0x40 != 0) {
      _twoVolumeVertex(words);
      return;
    }
    final colorType = (_pcw >> 4) & 3;
    final textured = _pcw & 8 != 0, offset = textured && _pcw & 4 != 0;
    int floatingColor(int start) {
      var color = 0;
      for (var i = start; i < start + 4; i++) {
        color = (color << 8) | (_component(words[i]) * 255).truncate();
      }
      return color & 0xffffffff;
    }

    int intensityColor(List<double>? face, int index) {
      if (face == null) _illegal('intensity color has no preceding face');
      final intensity = _component(words[index]);
      var color = (face[0] * 255).truncate() << 24;
      for (var i = 1; i < 4; i++) {
        color |= (face[i] * intensity * 255).truncate() << (24 - 8 * i);
      }
      return color & 0xffffffff;
    }

    final color = switch (colorType) {
      // HOLLY2 moves non-textured packed color to word 4 (Architecture §8.6).
      0 => words[textured ? 6 : 4],
      1 => floatingColor(textured ? 8 : 4),
      _ => intensityColor(_face, 6),
    };
    final vertex = <int>[words[1], words[2], words[3]];
    if (textured) {
      if (_pcw & 1 != 0) {
        if (!_value(words[4] & 0xffff0000).isFinite ||
            !_value((words[4] & 0xffff) << 16).isFinite) {
          _illegal('nonfinite UV coordinate');
        }
        vertex.add(words[4]);
      } else {
        if (!_value(words[4]).isFinite || !_value(words[5]).isFinite) {
          _illegal('nonfinite UV coordinate');
        }
        vertex.addAll([words[4], words[5]]);
      }
    }
    vertex.add(color & 0xffffffff);
    if (offset) {
      vertex.add(switch (colorType) {
        0 => words[7],
        1 => floatingColor(12),
        _ => intensityColor(_faceOffset, 7),
      });
    }
    _finishVertex(vertex, words[0]);
  }

  void _twoVolumeVertex(List<int> words) {
    final textured = _pcw & 8 != 0, offset = textured && _pcw & 4 != 0;
    final packed = (_pcw >> 4) & 3 == 0;
    final vertex = <int>[words[1], words[2], words[3]];
    for (var slot = 0; slot < 2; slot++) {
      final start = textured ? 4 + slot * 4 : 4 + slot;
      if (textured) {
        if (_pcw & 1 != 0) {
          if (!_value(words[start] & 0xffff0000).isFinite ||
              !_value((words[start] & 0xffff) << 16).isFinite) {
            _illegal('nonfinite two-volume UV');
          }
          vertex.add(words[start]);
        } else {
          if (!_value(words[start]).isFinite ||
              !_value(words[start + 1]).isFinite) {
            _illegal('nonfinite two-volume UV');
          }
          vertex.addAll([words[start], words[start + 1]]);
        }
      }
      final face = slot == 0 ? _face : _face1;
      int color(int index) {
        if (packed) return words[index];
        if (face == null) {
          _illegal('two-volume intensity has no preceding face');
        }
        final intensity = _component(words[index]);
        var result = (face[0] * 255).truncate() << 24;
        for (var channel = 1; channel < 4; channel++) {
          result |= (face[channel] * intensity * 255).truncate() <<
              (24 - channel * 8);
        }
        return result & 0xffffffff;
      }

      vertex.add(color(textured ? start + 2 : start));
      if (offset) vertex.add(color(start + 3));
    }
    _finishVertex(vertex, words[0]);
  }

  void _finishVertex(List<int> vertex, int pcw) {
    _vertices.add(vertex);
    final end = pcw & 0x10000000 != 0;
    if (end && _vertices.length < 3) {
      _illegal('strip has fewer than three vertices');
    }
    if (end || _vertices.length == _stripLength + 2) {
      _emit();
      if (end) {
        _vertices.clear();
        _triangle = 0;
      } else {
        final tail = _vertices.sublist(_vertices.length - 2);
        _vertices
          ..clear()
          ..addAll(tail);
      }
    }
  }

  void _modifierVertex(List<int> words) {
    if (words[0] & 0x10000000 == 0) {
      _illegal('modifier vertex must end its object');
    }
    for (var i = 1; i <= 9; i++) {
      if (!_value(words[i]).isFinite) _illegal('nonfinite modifier coordinate');
    }
    for (var i = 0; i < 3; i++) {
      _vertices.add(words.sublist(1 + i * 3, 4 + i * 3));
    }
    _emit(modifier: true);
    _vertices.clear();
    _triangle = 0;
  }

  void _spriteVertex(List<int> words) {
    if (words[0] & 0x10000000 == 0) {
      _illegal('sprite vertex must end its object');
    }
    for (var i = 1; i <= 11; i++) {
      if (!_value(words[i]).isFinite) _illegal('nonfinite sprite coordinate');
    }
    final textured = _pcw & 8 != 0, offset = textured && _pcw & 4 != 0;
    for (var i = 0; i < 4; i++) {
      final vertex = <int>[
        if (i < 3)
          ...words.sublist(1 + i * 3, 4 + i * 3)
        else ...[words[10], words[11], 0]
      ];
      if (textured) {
        final uv = i < 3 ? words[13 + i] : 0;
        if (!_value(uv & 0xffff0000).isFinite ||
            !_value((uv & 0xffff) << 16).isFinite) {
          _illegal('nonfinite sprite UV');
        }
        vertex.add(uv);
      }
      vertex.add(i < 3 ? _spriteColor : 0);
      if (offset) vertex.add(i < 3 ? _spriteOffset : 0);
      _vertices.add(vertex);
    }
    _emit(quad: true);
    _vertices.clear();
    _triangle = 0;
  }

  bool _visible(int x, int y) {
    if (x < 0 || y < 0 || x >= _width || y >= _height) return false;
    final inside =
        x >= _clip[0] && x <= _clip[2] && y >= _clip[1] && y <= _clip[3];
    return _clipMode == 0 || (_clipMode == 2 ? inside : !inside);
  }

  void _emit({bool quad = false, bool modifier = false}) {
    final triangles = quad || modifier ? 1 : _vertices.length - 2;
    final masks = <int, int>{};
    for (var i = 0; i < triangles; i++) {
      final vs = quad ? _vertices : _vertices.sublist(i, i + 3);
      final xs = vs.map((v) => _value(v[0]).truncateToDouble());
      final ys = vs.map((v) => _value(v[1]).truncateToDouble());
      final left = math.max(0.0, xs.reduce(math.min));
      final right = math.min((_width * 32 - 1).toDouble(), xs.reduce(math.max));
      final top = math.max(0.0, ys.reduce(math.min));
      final bottom =
          math.min((_height * 32 - 1).toDouble(), ys.reduce(math.max));
      if (left > right || top > bottom) continue;
      for (var y = top.toInt() ~/ 32; y <= bottom.toInt() ~/ 32; y++) {
        for (var x = left.toInt() ~/ 32; x <= right.toInt() ~/ 32; x++) {
          if (_visible(x, y)) {
            final tile = y * _width + x;
            masks[tile] =
                (masks[tile] ?? 0) | (quad || modifier ? 0 : 1 << (30 - i));
          }
        }
      }
    }
    // Provisional BIOS conversion-only path: no OPB means tile coverage must
    // not discard the converted parameters consumed separately by the CPU.
    if (masks.isNotEmpty || _blocks[_list].isEmpty) {
      final stride = _vertices.first.length;
      final twoVolumes = !_modifier && !_sprite && _pcw & 0x40 != 0;
      final header = twoVolumes ? 5 : 3;
      final size = (header + _vertices.length * stride) * 4;
      if (currentParameter < 0 ||
          currentParameter + size > memory.length ||
          currentParameter + size - 4 > parameterLimit) {
        onError(1 << 2);
        throw const DcUnsupported('TA ISP/TSP parameter overflow');
      }
      final data = <int>[
        _isp,
        _tsp,
        _texture,
        if (twoVolumes) ...[_tsp1, _texture1]
      ];
      // One-triangle partitions retain the original strip's alternating winding.
      final vertices = _vertices.toList();
      if (!quad && _triangle.isOdd) {
        final first = vertices[0];
        vertices[0] = vertices[1];
        vertices[1] = first;
      }
      for (final vertex in vertices) {
        data.addAll(vertex);
      }
      for (final (i, word) in data.indexed) {
        memory.setUint32LE(currentParameter + i * 4, word);
      }
      final pointer = (modifier
              ? 0x80000000
              : quad
                  ? 0xa0000000
                  : 0) |
          ((_pcw & 0x80) << 17) |
          (((stride - 3) ~/ (twoVolumes ? 2 : 1)) << 21) |
          // CORE adds its 1 MiB-aligned PARAM_BASE when following this pointer.
          ((currentParameter - (parameterBase & 0xf00000)) >> 2);
      for (final entry in masks.entries) {
        _append(entry.key, pointer | entry.value);
      }
      currentParameter += size;
    }
    _triangle += triangles;
  }

  void _register(int pointer, int left, int top, int right, int bottom) {
    if (left > right || top > bottom || right > 39 || bottom > 14) {
      _illegal('invalid object-set bounding box');
    }
    for (var y = top; y <= bottom; y++) {
      for (var x = left; x <= right; x++) {
        if (_visible(x, y)) _append(y * _width + x, pointer);
      }
    }
  }

  void _append(int tile, int pointer) {
    // No List suppresses OPB output; BIOS still uses parameter conversion.
    if (_blocks[_list].isEmpty) return;
    final block = _blocks[_list][tile];
    if (block.used == block.words - 1) {
      final address = nextObject, bytes = block.words * 4;
      _checkObject(address, bytes);
      memory.setUint32LE(block.address + block.used * 4, 0xe0000000 | address);
      nextObject += _activeAllocation & 0x100000 == 0 ? bytes : -bytes;
      block.address = address;
      block.used = 0;
    }
    memory.setUint32LE(block.address + block.used++ * 4, pointer);
  }

  void _endList() {
    if (_list < 0) _illegal('end without a selected list');
    if (_vertices.isNotEmpty) {
      _illegal('end before the last vertex ends its strip');
    }
    for (final block in _blocks[_list]) {
      memory.setUint32LE(block.address + block.used * 4, 0xf0000000);
    }
    final list = _list;
    _ended |= 1 << list;
    _list = -1;
    _header = false;
    onNormal(1 << [7, 8, 9, 10, 21][list]);
  }
}

class _Block {
  _Block(this.address, this.words);
  int address, used = 0;
  final int words;
}
