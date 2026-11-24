import 'dart:math' as math;
import 'dart:typed_data';

import '../../util/state.dart';
import 'allegrex.dart';
import 'memory.dart';

/// One queued display list. Execution is synchronous in this core: a list
/// runs when it is queued (or when its stall address moves) and then sits
/// in its final state, which the sync calls report.
class PspGeList {
  final int id;
  int start;
  int stall;
  int pc;
  int state;
  PspGeList(this.id, this.start, this.stall)
      : pc = start,
        state = PspGe.stateQueued;
}

/// A software implementation of the graphics engine: it keeps the command
/// register file, executes display lists from guest memory and rasterizes
/// into video memory.
///
/// The supported drawing path covers through-mode (2D) and transformed
/// (3D) vertices without skinning or lighting, points, lines, triangles,
/// strips, fans and sprites, textures in the direct and palette formats
/// (no compression), the texture functions, alpha, stencil and depth
/// testing, blending, the pixel mask, buffer clears through the clear mode,
/// and block transfers. Patches (Bezier and spline), fog, dithering, color
/// tests and logic operations are accepted but not rasterized.
class PspGe {
  final PspMemory mem;

  /// The last value written to each of the 256 commands.
  final regs = Uint32List(256);

  /// World, view, projection and texture matrices (16 floats each).
  final world = Float32List(16);
  final view = Float32List(16);
  final proj = Float32List(16);
  final tgen = Float32List(16);

  /// The eight bone matrices of skinned vertices, 16 floats each.
  final bones = Float32List(8 * 16);

  final lists = <int, PspGeList>{};
  int _nextListId = 1;
  int lastListId = 0;

  // Registered callbacks (guest function addresses, 0 when unset).
  int signalFunc = 0, signalArg = 0, finishFunc = 0, finishArg = 0;
  int _nextCallbackId = 1;
  int edramTranslation = 0;

  /// Runs a guest callback; set by the kernel, which owns the processor.
  void Function(Allegrex cpu, int func, int id, int arg)? callbackRunner;

  final _palette = Uint32List(1024);
  int _paletteCount = 0;

  // List execution state.
  int _base = 0;
  int _offset = 0;
  final _stack = <int>[];
  final _offsetStack = <int>[];

  static const stateDone = 0;
  static const stateQueued = 1;
  static const stateDrawingDone = 2;
  static const stateStalled = 3;
  static const stateCancelled = 4;

  PspGe(this.mem) {
    _identity(world);
    _identity(view);
    _identity(proj);
    _identity(tgen);
    for (var i = 0; i < 8; i++) {
      _identity(Float32List.sublistView(bones, i * 16, i * 16 + 16));
    }
  }

  static void _identity(Float32List m) {
    for (var i = 0; i < 16; i++) {
      m[i] = i % 5 == 0 ? 1 : 0;
    }
  }

  // Display list queue operations, called from the kernel handlers.

  int enqueue(Allegrex cpu, int list, int stall, {bool head = false}) {
    // List and stall addresses are normalized to physical form: jump
    // targets inside a list are physical too, and the stall comparison
    // in _run must see both in the same space.
    final entry = PspGeList(_nextListId++, PspMemory.physical(list),
        PspMemory.physical(stall));
    lists[entry.id] = entry;
    lastListId = entry.id;
    _run(cpu, entry);
    return entry.id;
  }

  int updateStall(Allegrex cpu, int id, int stall) {
    final entry = lists[id];
    if (entry == null) return -1;
    entry.stall = PspMemory.physical(stall);
    if (entry.state == stateStalled) _run(cpu, entry);
    return 0;
  }

  int dequeue(int id) {
    final entry = lists[id];
    if (entry == null) return -1;
    if (entry.state == stateQueued || entry.state == stateStalled) {
      entry.state = stateCancelled;
    }
    return 0;
  }

  int listState(int id) => lists[id]?.state ?? stateDone;

  int drawState() {
    final entry = lists[lastListId];
    return entry?.state ?? stateDone;
  }

  void breakQueue(bool reset) {
    if (!reset) return;
    for (final entry in lists.values) {
      if (entry.state == stateQueued || entry.state == stateStalled) {
        entry.state = stateCancelled;
      }
    }
  }

  int setCallback(int at) {
    if (at == 0) return -1;
    signalFunc = mem.read32(at);
    signalArg = mem.read32(at + 4);
    finishFunc = mem.read32(at + 8);
    finishArg = mem.read32(at + 12);
    return _nextCallbackId++;
  }

  void unsetCallback() {
    signalFunc = 0;
    finishFunc = 0;
  }

  void saveContext(int at) {
    for (var i = 0; i < 256; i++) {
      mem.write32(at + i * 4, regs[i]);
    }
    for (var i = 256; i < 512; i++) {
      mem.write32(at + i * 4, 0);
    }
  }

  void restoreContext(int at) {
    for (var i = 0; i < 256; i++) {
      regs[i] = mem.read32(at + i * 4);
    }
  }

  // Address helpers. Buffer addresses inside lists carry their low 24
  // bits in the pointer command and the top byte in the matching width
  // command. The graphics engine's address space starts at video memory,
  // so a combined address that lands below it is a video memory offset;
  // anything higher resolves through the shared physical map, which is
  // how textures in main memory are reached.
  int _addr(int low24, int widthArg) {
    final phys = PspMemory.physical(low24 | ((widthArg >> 16) & 0xff) << 24);
    return phys < PspMemory.vramAt ? PspMemory.vramAt + phys : phys;
  }

  int get _fbAddr => _addr(regs[0x9c], regs[0x9d]);
  int get _fbWidth => regs[0x9d] & 0xffff;
  int get _fbFormat => regs[0xd2] & 3;
  int get _zAddr => _addr(regs[0x9e], regs[0x9f]);
  int get _zWidth => regs[0x9f] & 0xffff;

  int _effective(int arg) =>
      _offset + ((_base & 0xff000000) | (arg & 0xffffff));

  static double _floatArg(int arg) {
    final view = ByteData(4);
    view.setUint32(0, (arg << 8) & 0xffffffff);
    return view.getFloat32(0).toDouble();
  }

  /// Executes a list from its saved program counter until it ends, stalls
  /// or exhausts a generous step budget (a malformed list must not hang
  /// the core).
  void _run(Allegrex cpu, PspGeList entry) {
    var pc = entry.pc;
    var budget = 1000000;
    _stack.clear();
    _offsetStack.clear();
    var signal = -1;
    while (budget-- > 0) {
      if (entry.stall != 0 && pc == entry.stall) {
        entry.pc = pc;
        entry.state = stateStalled;
        return;
      }
      final word = mem.read32(pc);
      pc += 4;
      final op = word >>> 24;
      final arg = word & 0xffffff;
      if (op != 0x04) regs[op] = arg;
      // the behavior of a SIGNAL just before this command, or -1
      final signalBefore = signal;
      signal = op == 0x0e ? (arg >> 16) & 0xff : -1;
      switch (op) {
        case 0x00: // NOP
          break;
        case 0x0c: // END
          // An END right after a SIGNAL completes the signal command
          // pair, as the public GE command lists describe, and the list
          // goes on; a pausing signal stops the list there.
          if (signalBefore >= 0 && signalBefore != 3) break;
          entry.pc = pc;
          entry.state = stateDone;
          return;
        case 0x0f: // FINISH
          if (entry.state != stateDone) entry.state = stateDrawingDone;
          if (finishFunc != 0) {
            callbackRunner?.call(cpu, finishFunc, arg & 0xffff, finishArg);
          }
          break;
        case 0x0e: // SIGNAL
          _signal(cpu, arg);
          break;
        case 0x08: // JUMP
          pc = _effective(arg);
          break;
        case 0x09: // BJUMP: jumps past an object when the preceding
          // bounding box (BBOX) test fails. The test is not evaluated and
          // every box counts as visible, so the jump is never taken.
          break;
        case 0x0a: // CALL
          _stack.add(pc);
          _offsetStack.add(_offset);
          pc = _effective(arg);
          break;
        case 0x0b: // RET
          if (_stack.isEmpty) {
            entry.pc = pc;
            entry.state = stateDone;
            return;
          }
          pc = _stack.removeLast();
          _offset = _offsetStack.removeLast();
          break;
        case 0x10: // BASE: the argument is the base address shifted by 8
          _base = arg << 8;
          break;
        case 0x01: // VADDR
          _vertexAt = _effective(arg);
          break;
        case 0x02: // IADDR
          _indexAt = _effective(arg);
          break;
        case 0x13: // OFFSETADDR
          _offset = arg << 8;
          break;
        case 0x14: // ORIGIN: the offset becomes the command's own address
          _offset = pc - 4;
          break;
        case 0x04: // PRIM
          regs[op] = arg;
          _prim(arg);
          break;
        case 0x2a: // bone matrix number: 12 elements per bone
          _boneIndex = arg & 0x7f;
          break;
        case 0x2b:
          if (_boneIndex < 96) {
            final bone = _boneIndex ~/ 12, i = _boneIndex % 12;
            bones[bone * 16 + (i ~/ 3) * 4 + (i % 3)] = _floatArg(arg);
          }
          _boneIndex++;
          break;
        case 0x3a:
        case 0x3c:
        case 0x3e:
        case 0x40:
          _matrixIndex[op] = arg & 0xf;
          break;
        case 0x3b:
          _matrixData(world, 0x3a, arg, packed: true);
          break;
        case 0x3d:
          _matrixData(view, 0x3c, arg, packed: true);
          break;
        case 0x3f:
          _matrixData(proj, 0x3e, arg);
          break;
        case 0x41:
          _matrixData(tgen, 0x40, arg, packed: true);
          break;
        case 0xc4: // LOADCLUT
          _loadClut(arg);
          break;
        case 0xea: // TRANSFERSTART
          _transfer(arg);
          break;
        default:
          break; // state commands live in the register file alone
      }
    }
    entry.pc = pc;
    entry.state = stateDone;
  }

  final _matrixIndex = <int, int>{};

  /// The vertex and index addresses: set by their commands and moved past
  /// what each primitive reads, so the next one continues from there.
  int _vertexAt = 0, _indexAt = 0;
  int _boneIndex = 0;

  void _matrixData(Float32List m, int numberOp, int arg, {bool packed = false}) {
    final index = _matrixIndex[numberOp] ?? 0;
    if (packed) {
      // The world, view and texture matrices upload three elements per
      // column; the fourth row is fixed at (0, 0, 0, 1).
      if (index < 12) {
        m[(index ~/ 3) * 4 + (index % 3)] = _floatArg(arg).toDouble();
      }
    } else if (index < 16) {
      m[index] = _floatArg(arg).toDouble();
    }
    _matrixIndex[numberOp] = index + 1;
  }

  void _signal(Allegrex cpu, int arg) {
    final behavior = (arg >> 16) & 0xff;
    final value = arg & 0xffff;
    switch (behavior) {
      case 0x10: // jump
      case 0x11: // call
      case 0x12: // return
        // Signal-driven list flow is not followed; the common suspend and
        // continue behaviors below cover the library's use.
        break;
      default:
        if (signalFunc != 0) {
          callbackRunner?.call(cpu, signalFunc, value, signalArg);
        }
        break;
    }
  }

  void _loadClut(int arg) {
    // The high address bits ride in bits 16-23 of the second command,
    // as with the other buffer pointers.
    final addr = (((regs[0xb1] >> 16) & 0xff) << 24) | regs[0xb0];
    final format = regs[0xc5] & 3;
    final blocks = (arg & 0x3f) == 0 ? 64 : arg & 0x3f;
    // One block holds 32 bytes of palette: 8 entries at 32 bits, 16 at 16.
    final total = blocks * (format == 3 ? 8 : 16);
    final phys = PspMemory.physical(addr);
    _paletteCount = 0;
    for (var i = 0; i < total && _paletteCount < 1024; i++) {
      if (format == 3) {
        _palette[_paletteCount++] = mem.read32(phys + i * 4);
      } else {
        final v = mem.read16(phys + i * 2);
        _palette[_paletteCount++] = _expand16(v, format);
      }
    }
  }

  static int _expand16(int v, int format) {
    switch (format) {
      case 0:
        final r = (v & 0x1f) << 3 | (v & 0x1f) >> 2;
        final g = (v >> 5 & 0x3f) << 2 | (v >> 5 & 0x3f) >> 4;
        final b = (v >> 11 & 0x1f) << 3 | (v >> 11 & 0x1f) >> 2;
        return 0xff000000 | r | g << 8 | b << 16;
      case 1:
        final r = (v & 0x1f) << 3 | (v & 0x1f) >> 2;
        final g = (v >> 5 & 0x1f) << 3 | (v >> 5 & 0x1f) >> 2;
        final b = (v >> 10 & 0x1f) << 3 | (v >> 10 & 0x1f) >> 2;
        return (v & 0x8000 != 0 ? 0xff000000 : 0) | r | g << 8 | b << 16;
      case 2:
        final r = (v & 0xf) << 4 | v & 0xf;
        final g = (v >> 4 & 0xf) << 4 | (v >> 4 & 0xf);
        final b = (v >> 8 & 0xf) << 4 | (v >> 8 & 0xf);
        final a = (v >> 12 & 0xf) << 4 | (v >> 12 & 0xf);
        return a << 24 | r | g << 8 | b << 16;
      default:
        return v; // 32-bit entries are stored red first, as in memory
    }
  }

  void _transfer(int arg) {
    final src = _addr(regs[0xb2], regs[0xb3]);
    final dst = _addr(regs[0xb4], regs[0xb5]);
    final srcPitch = regs[0xb3] & 0x7ff;
    final dstPitch = regs[0xb5] & 0x7ff;
    if (srcPitch == 0 || dstPitch == 0) return;
    final sx = regs[0xeb] & 0x3ff, sy = (regs[0xeb] >> 10) & 0x3ff;
    final dx = regs[0xec] & 0x3ff, dy = (regs[0xec] >> 10) & 0x3ff;
    final w = (regs[0xee] & 0x3ff) + 1, h = ((regs[0xee] >> 10) & 0x3ff) + 1;
    final bpp = (arg & 1) == 0 ? 2 : 4;
    for (var y = 0; y < h; y++) {
      final s = src + ((sy + y) * srcPitch + sx) * bpp;
      final d = dst + ((dy + y) * dstPitch + dx) * bpp;
      for (var i = 0; i < w * bpp; i++) {
        mem.write8(d + i, mem.read8(s + i));
      }
    }
  }

  void saveState(StateWriter writer) {
    writer.section('ge');
    writer.ints(regs);
    writer.bytes(
        world.buffer.asUint8List(world.offsetInBytes, world.lengthInBytes));
    writer
        .bytes(view.buffer.asUint8List(view.offsetInBytes, view.lengthInBytes));
    writer
        .bytes(proj.buffer.asUint8List(proj.offsetInBytes, proj.lengthInBytes));
    writer.bytes(
        bones.buffer.asUint8List(bones.offsetInBytes, bones.lengthInBytes));
    writer.int32(_vertexAt);
    writer.int32(_indexAt);
    writer.int32(signalFunc);
    writer.int32(signalArg);
    writer.int32(finishFunc);
    writer.int32(finishArg);
    writer.int32(lastListId);
    writer.int32(_nextListId);
    writer.int32(lists.length);
    for (final entry in lists.values) {
      writer.int32(entry.id);
      writer.int32(entry.start);
      writer.int32(entry.stall);
      writer.int32(entry.pc);
      writer.int32(entry.state);
    }
    writer.int32(_paletteCount);
    writer.ints(_palette.sublist(0, _paletteCount));
  }

  void loadState(StateReader reader) {
    reader.section('ge');
    reader.intsInto(regs);
    reader.bytesInto(
        world.buffer.asUint8List(world.offsetInBytes, world.lengthInBytes));
    reader.bytesInto(
        view.buffer.asUint8List(view.offsetInBytes, view.lengthInBytes));
    reader.bytesInto(
        proj.buffer.asUint8List(proj.offsetInBytes, proj.lengthInBytes));
    if (reader.version >= 6) {
      reader.bytesInto(
          bones.buffer.asUint8List(bones.offsetInBytes, bones.lengthInBytes));
      _vertexAt = reader.int32();
      _indexAt = reader.int32();
    }
    signalFunc = reader.int32();
    signalArg = reader.int32();
    finishFunc = reader.int32();
    finishArg = reader.int32();
    lastListId = reader.int32();
    _nextListId = reader.int32();
    lists.clear();
    final count = reader.int32();
    for (var i = 0; i < count; i++) {
      final id = reader.int32();
      final entry = PspGeList(id, reader.int32(), reader.int32());
      entry.pc = reader.int32();
      entry.state = reader.int32();
      lists[id] = entry;
    }
    _paletteCount = reader.int32();
    final values = reader.ints();
    _palette.setRange(0, values.length, values);
  }
}

/// A decoded vertex in screen space. Texture coordinates are in texel
/// units; [su], [sv] and [invW] carry the perspective-correct values.
class _Vertex {
  double x = 0, y = 0, z = 0;
  double su = 0, sv = 0, invW = 1;
  double r = 1, g = 1, b = 1, a = 1;

  /// The clip-space position and the texture coordinates before the
  /// perspective division, kept to clip triangles against the near plane.
  double cx = 0, cy = 0, cz = 0, cw = 1, tu = 0, tv = 0;

  /// True if the vertex lies in front of the near plane (z < -w), which
  /// the libraries' projections put there; whether the hardware clips at
  /// this plane is not verified. Triangles are clipped against it, other
  /// primitives with such a vertex are dropped.
  bool behind = false;
}

extension PspGeDrawing on PspGe {
  static final _f32 = ByteData(4);

  static double _bitsToFloat(int bits) {
    _f32.setUint32(0, bits & 0xffffffff);
    return _f32.getFloat32(0).toDouble();
  }

  /// Executes one PRIM command: decodes the vertices and rasterizes.
  void _prim(int arg) {
    final count = arg & 0xffff;
    final type = (arg >> 16) & 7;
    if (count == 0 || type > 6) return;
    final vertices = _readVertices(count);
    if (vertices.isEmpty) return;
    if (regs[0xd3] & 1 != 0) {
      _clearPrim(type, vertices);
      return;
    }
    switch (type) {
      case 0: // points
        for (final v in vertices) {
          _plot(v, pointSample: true);
        }
        break;
      case 1: // lines
        for (var i = 0; i + 1 < vertices.length; i += 2) {
          _line(vertices[i], vertices[i + 1]);
        }
        break;
      case 2: // line strip
        for (var i = 0; i + 1 < vertices.length; i++) {
          _line(vertices[i], vertices[i + 1]);
        }
        break;
      case 3: // triangles
        for (var i = 0; i + 2 < vertices.length; i += 3) {
          _triangle(vertices[i], vertices[i + 1], vertices[i + 2]);
        }
        break;
      case 4: // triangle strip
        for (var i = 0; i + 2 < vertices.length; i++) {
          if (i.isEven) {
            _triangle(vertices[i], vertices[i + 1], vertices[i + 2]);
          } else {
            _triangle(vertices[i + 1], vertices[i], vertices[i + 2]);
          }
        }
        break;
      case 5: // triangle fan
        for (var i = 1; i + 1 < vertices.length; i++) {
          _triangle(vertices[0], vertices[i], vertices[i + 1]);
        }
        break;
      case 6: // sprites: pairs of opposite corners
        for (var i = 0; i + 1 < vertices.length; i += 2) {
          _sprite(vertices[i], vertices[i + 1]);
        }
        break;
    }
  }

  void _clearPrim(int type, List<_Vertex> vertices) {
    final flags = (regs[0xd3] >> 8) & 0xff;
    if (type == 6) {
      for (var i = 0; i + 1 < vertices.length; i += 2) {
        _clearRect(vertices[i], vertices[i + 1], flags);
      }
    } else if (vertices.isNotEmpty) {
      // A non-sprite clear primitive clears the whole draw region with
      // the last vertex's color and depth.
      final v = vertices.last;
      final whole = _Vertex()
        ..x = 0
        ..y = 0
        ..z = v.z
        ..r = v.r
        ..g = v.g
        ..b = v.b
        ..a = v.a;
      final corner = _Vertex()
        ..x = _fbWidth.toDouble()
        ..y = 272
        ..z = v.z
        ..r = v.r
        ..g = v.g
        ..b = v.b
        ..a = v.a;
      _clearRect(whole, corner, flags);
    }
  }

  void _clearRect(_Vertex a, _Vertex b, int flags) {
    final clip = _clipRect();
    final x0 = math.max(clip[0], math.min(a.x, b.x).floor());
    final y0 = math.max(clip[1], math.min(a.y, b.y).floor());
    final x1 = math.min(clip[2], math.max(a.x, b.x).ceil());
    final y1 = math.min(clip[3], math.max(a.y, b.y).ceil());
    final color = _encodePixel(b.r, b.g, b.b, b.a);
    final depth = b.z.round().clamp(0, 65535);
    // Flag 1 clears the color bits and flag 2 the alpha (stencil) bits.
    final full = _fbFormat == 3 ? 0xffffffff : 0xffff;
    final alpha = _alphaMask;
    final cleared = ((flags & 1 != 0 ? ~alpha : 0) |
            (flags & 2 != 0 ? alpha : 0)) &
        full;
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        if (cleared == full) {
          _writeRaw(x, y, color);
        } else if (cleared != 0) {
          _writeRaw(x, y, (_readRaw(x, y) & ~cleared) | (color & cleared));
        }
        if (flags & 4 != 0) _writeDepth(x, y, depth);
      }
    }
  }

  /// The clip rectangle [x0, y0, x1, y1) from the region and scissor
  /// registers, intersected with the frame buffer extent.
  List<int> _clipRect() {
    var x0 = 0, y0 = 0, x1 = _fbWidth, y1 = _maxY();
    void apply(int first, int second) {
      if (second == 0) return; // unset registers mean the full extent
      x0 = math.max(x0, first & 0x3ff);
      y0 = math.max(y0, (first >> 10) & 0x3ff);
      x1 = math.min(x1, (second & 0x3ff) + 1);
      y1 = math.min(y1, ((second >> 10) & 0x3ff) + 1);
    }

    apply(regs[0x15], regs[0x16]); // region
    apply(regs[0xd4], regs[0xd5]); // scissor
    return [x0, y0, math.max(x0, x1), math.max(y0, y1)];
  }

  int _maxY() {
    final bpp = _fbFormat == 3 ? 4 : 2;
    if (_fbWidth <= 0) return 0;
    final end = _fbAddr >= PspMemory.ramAt
        ? PspMemory.ramEnd
        : PspMemory.vramAt + PspMemory.vramSize;
    final lines = (end - _fbAddr) ~/ (_fbWidth * bpp);
    return math.max(0, math.min(lines, 512));
  }

  List<_Vertex> _readVertices(int count) {
    final vtype = regs[0x12];
    final texType = vtype & 3;
    final colorType = (vtype >> 2) & 7;
    final normalType = (vtype >> 5) & 3;
    final posType = (vtype >> 7) & 3;
    final weightType = (vtype >> 9) & 3;
    final indexType = (vtype >> 11) & 3;
    final numWeights = ((vtype >> 14) & 7) + 1;
    final through = vtype & 0x800000 != 0;
    if (posType == 0) return const [];

    // Component layout: weights, texture, color, normal, position; each
    // component aligned to its element size, the vertex to the largest.
    var offset = 0;
    var maxAlign = 1;
    int place(int elements, int size) {
      if (elements == 0 || size == 0) return -1;
      offset = (offset + size - 1) & ~(size - 1);
      final at = offset;
      offset += elements * size;
      if (size > maxAlign) maxAlign = size;
      return at;
    }

    int sizeOf(int type) => type == 1
        ? 1
        : type == 2
            ? 2
            : 4;
    final weightAt =
        place(weightType == 0 ? 0 : numWeights, sizeOf(weightType));
    final texAt = place(texType == 0 ? 0 : 2, sizeOf(texType));
    final colorSize = colorType == 0 ? 0 : (colorType == 7 ? 4 : 2);
    final colorAt = place(colorType == 0 ? 0 : 1, colorSize);
    final normalAt = place(normalType == 0 ? 0 : 3, sizeOf(normalType));
    final posAt = place(3, sizeOf(posType));
    final stride = (offset + maxAlign - 1) & ~(maxAlign - 1);

    final base = _vertexAt;
    final indexBase = _indexAt;
    if (indexType == 0) {
      _vertexAt += count * stride;
    } else {
      _indexAt += count * indexType;
    }
    final result = <_Vertex>[];
    for (var i = 0; i < count; i++) {
      var index = i;
      if (indexType == 1) {
        index = mem.read8(indexBase + i);
      } else if (indexType == 2) {
        index = mem.read16(indexBase + i * 2);
      }
      final at = base + index * stride;
      final v = _readVertex(
          at, texAt, texType, colorAt, colorType, posAt, posType, through,
          weightAt: through ? -1 : weightAt,
          weightType: weightType,
          numWeights: numWeights,
          normalAt: normalAt,
          normalType: normalType);
      result.add(v);
    }
    return result;
  }

  _Vertex _readVertex(int at, int texAt, int texType, int colorAt,
      int colorType, int posAt, int posType, bool through,
      {int weightAt = -1,
      int weightType = 0,
      int numWeights = 0,
      int normalAt = -1,
      int normalType = 0}) {
    final v = _Vertex();
    double component(int offset, int type, {bool signed = true}) {
      switch (type) {
        case 1:
          final b = mem.read8(at + offset);
          return (signed && b >= 0x80 ? b - 0x100 : b).toDouble();
        case 2:
          final s = mem.read16(at + offset);
          return (signed && s >= 0x8000 ? s - 0x10000 : s).toDouble();
        default:
          return _bitsToFloat(mem.read32(at + offset));
      }
    }

    var u = 0.0, w = 0.0;
    if (texAt >= 0) {
      final size = texType == 1
          ? 1
          : texType == 2
              ? 2
              : 4;
      u = component(texAt, texType, signed: false);
      w = component(texAt + size, texType, signed: false);
    }
    if (colorAt < 0) {
      // A vertex without a color takes the material's ambient color and
      // alpha, which the color commands of the libraries set.
      final c = regs[0x55];
      v.r = (c & 0xff) / 255;
      v.g = (c >> 8 & 0xff) / 255;
      v.b = (c >> 16 & 0xff) / 255;
      v.a = (regs[0x58] & 0xff) / 255;
    } else {
      if (colorType == 7) {
        final c = mem.read32(at + colorAt);
        v.r = (c & 0xff) / 255;
        v.g = (c >> 8 & 0xff) / 255;
        v.b = (c >> 16 & 0xff) / 255;
        v.a = (c >> 24 & 0xff) / 255;
      } else {
        final c = PspGe._expand16(mem.read16(at + colorAt), colorType - 4);
        v.r = (c & 0xff) / 255;
        v.g = (c >> 8 & 0xff) / 255;
        v.b = (c >> 16 & 0xff) / 255;
        v.a = (c >> 24 & 0xff) / 255;
      }
    }
    final posSize = posType == 1
        ? 1
        : posType == 2
            ? 2
            : 4;
    var px = component(posAt, posType);
    var py = component(posAt + posSize, posType);
    // Through-mode positions are already in screen space: x and y are
    // signed pixel coordinates and z is the unsigned depth value.
    var pz = through
        ? component(posAt + posSize * 2, posType, signed: false)
        : component(posAt + posSize * 2, posType);
    if (through) {
      v.x = px;
      v.y = py;
      v.z = pz.clamp(0, 65535);
      v.su = u;
      v.sv = w;
      v.invW = 1;
    } else {
      // Transformed 8 and 16-bit positions are fixed point with 7 and 15
      // fraction bits. The scale follows the vertex format description in
      // public GE documentation; it is not checked against hardware.
      if (posType != 3) {
        final scale = posType == 1 ? 1 / 128 : 1 / 32768;
        px *= scale;
        py *= scale;
        pz *= scale;
      }
      if (weightAt >= 0) {
        // Skinning: the weighted sum of the position under each bone.
        // Fixed point weights have 7 and 15 fraction bits like positions.
        final size = weightType == 1
            ? 1
            : weightType == 2
                ? 2
                : 4;
        final scale = weightType == 1
            ? 1 / 128
            : weightType == 2
                ? 1 / 32768
                : 1.0;
        var sx = 0.0, sy = 0.0, sz = 0.0;
        for (var i = 0; i < numWeights; i++) {
          final weight =
              component(weightAt + i * size, weightType, signed: false) *
                  scale;
          if (weight == 0) continue;
          final m = i * 16;
          sx += weight *
              (bones[m] * px + bones[m + 4] * py + bones[m + 8] * pz +
                  bones[m + 12]);
          sy += weight *
              (bones[m + 1] * px + bones[m + 5] * py + bones[m + 9] * pz +
                  bones[m + 13]);
          sz += weight *
              (bones[m + 2] * px + bones[m + 6] * py + bones[m + 10] * pz +
                  bones[m + 14]);
        }
        px = sx;
        py = sy;
        pz = sz;
      }
      // Model -> world -> view -> projection, then the viewport.
      final p = _transform(px, py, pz);
      v
        ..cx = p[0]
        ..cy = p[1]
        ..cz = p[2]
        ..cw = p[3];
      // Texture coordinates of transformed vertices are normalized; the
      // fixed point forms have 7 and 15 fraction bits, like the positions.
      if (texType == 3) {
        v.tu = u;
        v.tv = w;
      } else if (texType != 0) {
        final full = texType == 1 ? 128.0 : 32768.0;
        v.tu = u / full;
        v.tv = w / full;
      }
      if (regs[0xc0] & 3 == 1) {
        // Texture matrix mapping: the texture matrix maps the model
        // position, the texture coordinates or the normal to (s, t, q),
        // and the coordinates are s / q and t / q.
        var sx = px, sy = py, sz = pz;
        final source = (regs[0xc0] >> 8) & 3;
        if (source == 1) {
          sx = v.tu;
          sy = v.tv;
          sz = 0;
        } else if (source >= 2) {
          sx = sy = sz = 0;
          if (normalAt >= 0) {
            final scale = normalType == 1
                ? 1 / 128
                : normalType == 2
                    ? 1 / 32768
                    : 1.0;
            final size = normalType == 1
                ? 1
                : normalType == 2
                    ? 2
                    : 4;
            sx = component(normalAt, normalType) * scale;
            sy = component(normalAt + size, normalType) * scale;
            sz = component(normalAt + size * 2, normalType) * scale;
          }
          if (source == 2) {
            final length = math.sqrt(sx * sx + sy * sy + sz * sz);
            if (length != 0) {
              sx /= length;
              sy /= length;
              sz /= length;
            }
          }
        }
        final m = tgen;
        final s = m[0] * sx + m[4] * sy + m[8] * sz + m[12];
        final t = m[1] * sx + m[5] * sy + m[9] * sz + m[13];
        final q = m[2] * sx + m[6] * sy + m[10] * sz + m[14];
        final invQ = q == 0 ? 0.0 : 1 / q;
        v.tu = s * invQ;
        v.tv = t * invQ;
      }
      _project(v);
    }
    return v;
  }

  /// Divides the clip-space position of [v] by w and maps it through the
  /// viewport.
  void _project(_Vertex v) {
    v.behind = v.cz < -v.cw;
    final invW = v.cw == 0 ? 0.0 : 1 / v.cw;
    final nx = v.cx * invW, ny = v.cy * invW, nz = v.cz * invW;
    // The viewport scale and center produce coordinates around the
    // 2048 center; the offset registers (12.4 fixed point) locate the
    // framebuffer's origin inside that space.
    v.x = nx * PspGe._floatArg(regs[0x42]) +
        PspGe._floatArg(regs[0x45]) -
        regs[0x4c] / 16;
    v.y = ny * PspGe._floatArg(regs[0x43]) +
        PspGe._floatArg(regs[0x46]) -
        regs[0x4d] / 16;
    final sz = nz * PspGe._floatArg(regs[0x44]) + PspGe._floatArg(regs[0x47]);
    v.z = sz.clamp(
        (regs[0xd6] & 0xffff).toDouble(), (regs[0xd7] & 0xffff).toDouble());
    v.su = v.tu * invW;
    v.sv = v.tv * invW;
    v.invW = invW;
  }

  /// The parts of the triangle [a] [b] [c] behind the near plane, as a fan
  /// of triangles, or nothing if it lies wholly in front of the plane.
  List<_Vertex> _clipNear(_Vertex a, _Vertex b, _Vertex c) {
    final out = <_Vertex>[];
    final ring = [a, b, c];
    for (var i = 0; i < 3; i++) {
      final p = ring[i], q = ring[(i + 1) % 3];
      final dp = p.cz + p.cw, dq = q.cz + q.cw;
      if (dp >= 0) out.add(p);
      if ((dp >= 0) != (dq >= 0)) {
        final t = dp / (dp - dq);
        double mix(double x, double y) => x + (y - x) * t;
        final v = _Vertex()
          ..cx = mix(p.cx, q.cx)
          ..cy = mix(p.cy, q.cy)
          ..cz = mix(p.cz, q.cz)
          ..cw = mix(p.cw, q.cw)
          ..tu = mix(p.tu, q.tu)
          ..tv = mix(p.tv, q.tv)
          ..r = mix(p.r, q.r)
          ..g = mix(p.g, q.g)
          ..b = mix(p.b, q.b)
          ..a = mix(p.a, q.a);
        _project(v);
        // a point on the plane counts as in front of it
        v.behind = false;
        out.add(v);
      }
    }
    return out;
  }

  List<double> _transform(double x, double y, double z) {
    List<double> apply(Float32List m, List<double> p) => [
          m[0] * p[0] + m[4] * p[1] + m[8] * p[2] + m[12] * p[3],
          m[1] * p[0] + m[5] * p[1] + m[9] * p[2] + m[13] * p[3],
          m[2] * p[0] + m[6] * p[1] + m[10] * p[2] + m[14] * p[3],
          m[3] * p[0] + m[7] * p[1] + m[11] * p[2] + m[15] * p[3],
        ];
    return apply(proj, apply(view, apply(world, [x, y, z, 1])));
  }
}

extension PspGeRaster on PspGe {
  bool get _textured => regs[0x1e] & 1 != 0;
  bool get _smooth => regs[0x50] & 1 != 0;

  void _sprite(_Vertex a, _Vertex b) {
    if (a.behind || b.behind) return;
    final clip = _clipRect();
    final x0 = math.max(clip[0], math.min(a.x, b.x).floor());
    final y0 = math.max(clip[1], math.min(a.y, b.y).floor());
    final x1 = math.min(clip[2], math.max(a.x, b.x).ceil());
    final y1 = math.min(clip[3], math.max(a.y, b.y).ceil());
    final spanX = (b.x - a.x).abs() < 0.001 ? 1.0 : b.x - a.x;
    final spanY = (b.y - a.y).abs() < 0.001 ? 1.0 : b.y - a.y;
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        final s = _Vertex()
          ..x = x.toDouble()
          ..y = y.toDouble()
          ..z = b.z
          ..su = a.su + (b.su - a.su) * (x + 0.5 - a.x) / spanX
          ..sv = a.sv + (b.sv - a.sv) * (y + 0.5 - a.y) / spanY
          ..invW = 1
          ..r = b.r
          ..g = b.g
          ..b = b.b
          ..a = b.a;
        _shade(s);
      }
    }
  }

  void _triangle(_Vertex a, _Vertex b, _Vertex c) {
    if (a.behind || b.behind || c.behind) {
      final fan = _clipNear(a, b, c);
      for (var i = 1; i + 1 < fan.length; i++) {
        var last = fan[i + 1];
        if (!_smooth && last != c) {
          // flat shading takes the last vertex's color: keep the
          // original's on a copy, as strips share their vertices
          last = _Vertex()
            ..x = last.x
            ..y = last.y
            ..z = last.z
            ..su = last.su
            ..sv = last.sv
            ..invW = last.invW
            ..r = c.r
            ..g = c.g
            ..b = c.b
            ..a = c.a;
        }
        _triangle(fan[0], fan[i], last);
      }
      return;
    }
    if (regs[0x1d] & 1 != 0) {
      final area = (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y);
      final ccwFront = regs[0x9b] & 1 != 0;
      // The viewport flip makes a counter-clockwise front face appear
      // with a positive screen-space area.
      final front = ccwFront ? area > 0 : area < 0;
      if (!front || area == 0) return;
    }
    final clip = _clipRect();
    final minX = math.max(clip[0], math.min(a.x, math.min(b.x, c.x)).floor());
    final maxX =
        math.min(clip[2] - 1, math.max(a.x, math.max(b.x, c.x)).ceil());
    final minY = math.max(clip[1], math.min(a.y, math.min(b.y, c.y)).floor());
    final maxY =
        math.min(clip[3] - 1, math.max(a.y, math.max(b.y, c.y)).ceil());
    final denom = (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y);
    if (denom == 0) return;
    final flat = !_smooth;
    for (var y = minY; y <= maxY; y++) {
      for (var x = minX; x <= maxX; x++) {
        final px = x + 0.5, py = y + 0.5;
        final w0 =
            ((b.y - c.y) * (px - c.x) + (c.x - b.x) * (py - c.y)) / denom;
        final w1 =
            ((c.y - a.y) * (px - c.x) + (a.x - c.x) * (py - c.y)) / denom;
        final w2 = 1 - w0 - w1;
        if (w0 < 0 || w1 < 0 || w2 < 0) continue;
        final s = _Vertex()
          ..x = x.toDouble()
          ..y = y.toDouble()
          ..z = w0 * a.z + w1 * b.z + w2 * c.z
          ..su = w0 * a.su + w1 * b.su + w2 * c.su
          ..sv = w0 * a.sv + w1 * b.sv + w2 * c.sv
          ..invW = w0 * a.invW + w1 * b.invW + w2 * c.invW;
        if (flat) {
          s.r = c.r;
          s.g = c.g;
          s.b = c.b;
          s.a = c.a;
        } else {
          s.r = w0 * a.r + w1 * b.r + w2 * c.r;
          s.g = w0 * a.g + w1 * b.g + w2 * c.g;
          s.b = w0 * a.b + w1 * b.b + w2 * c.b;
          s.a = w0 * a.a + w1 * b.a + w2 * c.a;
        }
        _shade(s);
      }
    }
  }

  void _line(_Vertex a, _Vertex b) {
    if (a.behind || b.behind) return;
    final steps = math.max((b.x - a.x).abs(), (b.y - a.y).abs()).ceil();
    if (steps == 0) {
      _plot(a);
      return;
    }
    for (var i = 0; i <= steps; i++) {
      final t = i / steps;
      final s = _Vertex()
        ..x = a.x + (b.x - a.x) * t
        ..y = a.y + (b.y - a.y) * t
        ..z = a.z + (b.z - a.z) * t
        ..su = a.su + (b.su - a.su) * t
        ..sv = a.sv + (b.sv - a.sv) * t
        ..invW = 1
        ..r = a.r + (b.r - a.r) * t
        ..g = a.g + (b.g - a.g) * t
        ..b = a.b + (b.b - a.b) * t
        ..a = a.a + (b.a - a.a) * t;
      _plot(s);
    }
  }

  void _plot(_Vertex v, {bool pointSample = false}) {
    if (v.behind) return;
    final clip = _clipRect();
    final x = v.x.floor(), y = v.y.floor();
    if (x < clip[0] || y < clip[1] || x >= clip[2] || y >= clip[3]) return;
    final s = _Vertex()
      ..x = x.toDouble()
      ..y = y.toDouble()
      ..z = v.z
      ..su = v.su
      ..sv = v.sv
      ..invW = v.invW
      ..r = v.r
      ..g = v.g
      ..b = v.b
      ..a = v.a;
    _shade(s);
  }

  /// The per-fragment pipeline: texture, texture function, alpha test,
  /// depth test, blending and the frame buffer write.
  void _shade(_Vertex v) {
    var r = v.r, g = v.g, b = v.b, a = v.a;
    if (_textured) {
      final tex = _sample(v);
      final func = regs[0xc9] & 7;
      final rgba = (regs[0xc9] >> 8) & 1 != 0;
      final env = regs[0xca];
      final er = (env & 0xff) / 255,
          eg = (env >> 8 & 0xff) / 255,
          eb = (env >> 16 & 0xff) / 255;
      switch (func) {
        case 0: // modulate
          r *= tex[0];
          g *= tex[1];
          b *= tex[2];
          if (rgba) a *= tex[3];
          break;
        case 1: // decal
          if (rgba) {
            r = r * (1 - tex[3]) + tex[0] * tex[3];
            g = g * (1 - tex[3]) + tex[1] * tex[3];
            b = b * (1 - tex[3]) + tex[2] * tex[3];
          } else {
            r = tex[0];
            g = tex[1];
            b = tex[2];
          }
          break;
        case 2: // blend
          r = r * (1 - tex[0]) + er * tex[0];
          g = g * (1 - tex[1]) + eg * tex[1];
          b = b * (1 - tex[2]) + eb * tex[2];
          if (rgba) a *= tex[3];
          break;
        case 3: // replace
          r = tex[0];
          g = tex[1];
          b = tex[2];
          if (rgba) a = tex[3];
          break;
        case 4: // add
          r = math.min(1.0, r + tex[0]);
          g = math.min(1.0, g + tex[1]);
          b = math.min(1.0, b + tex[2]);
          if (rgba) a *= tex[3];
          break;
      }
    }
    final x = v.x.floor(), y = v.y.floor();
    if (regs[0x22] & 1 != 0) {
      final test = regs[0xdb];
      final ref = (test >> 8) & 0xff, mask = (test >> 16) & 0xff;
      final value = (a * 255).round() & mask;
      if (!_compare(test & 7, value, ref & mask)) return;
    }
    final dstRaw = _readRaw(x, y);
    // The stencil is the frame buffer's alpha (none in 5650).
    final stencilOn = regs[0x24] & 1 != 0 && _fbFormat != 0;
    if (stencilOn) {
      final test = regs[0xdc];
      final ref = (test >> 8) & 0xff, mask = (test >> 16) & 0xff;
      // The reference is compared against the stored value, in that
      // order; the order of the less and greater functions is unverified.
      if (!_compare(test & 7, ref & mask, _stencil8(dstRaw) & mask)) {
        _writeStencil(x, y, dstRaw, regs[0xdd] & 7);
        return;
      }
    }
    final z = v.z.round().clamp(0, 65535);
    if (regs[0x23] & 1 != 0 && _zWidth > 0) {
      final stored = _readDepth(x, y);
      if (!_compare(regs[0xde] & 7, z, stored)) {
        if (stencilOn) _writeStencil(x, y, dstRaw, (regs[0xdd] >> 8) & 7);
        return;
      }
    }
    var out = _encodePixel(r, g, b, a);
    if (regs[0x21] & 1 != 0) {
      final dst = _decodePixel(dstRaw);
      out = _encodePixel(
          _blendChannel(r, dst[0], a, dst[3], 0),
          _blendChannel(g, dst[1], a, dst[3], 1),
          _blendChannel(b, dst[2], a, dst[3], 2),
          _blendChannel(a, dst[3], a, dst[3], 3));
    }
    // The alpha bits change only through the stencil operations; with
    // the stencil test off they keep their value. This is inferred from
    // a game whose stencil shadow needs the alpha a clear left behind.
    final alpha = _alphaMask;
    final stencil = stencilOn
        ? _stencilRaw(_stencilOp((regs[0xdd] >> 16) & 7, dstRaw))
        : dstRaw & alpha;
    out = (out & ~alpha) | stencil;
    final keep = _keepMask;
    _writeRaw(x, y, (dstRaw & keep) | (out & ~keep));
    if (regs[0x23] & 1 != 0 && regs[0xe7] & 1 == 0 && _zWidth > 0) {
      _writeDepth(x, y, z);
    }
  }

  /// The frame buffer bits that hold the alpha (the stencil).
  int get _alphaMask => const [0, 0x8000, 0xf000, 0xff000000][_fbFormat];

  /// The frame buffer bits the pixel mask protects from writes.
  int get _keepMask {
    final rgb = regs[0xe8], al = regs[0xe9] & 0xff;
    return _encodeBytes(
        rgb & 0xff, (rgb >> 8) & 0xff, (rgb >> 16) & 0xff, al);
  }

  /// The stencil of a frame buffer pixel at the format's width.
  int _stencilOf(int raw) => switch (_fbFormat) {
        1 => (raw >> 15) & 1,
        2 => (raw >> 12) & 0xf,
        3 => (raw >> 24) & 0xff,
        _ => 0,
      };

  /// The stencil scaled to eight bits for the test.
  int _stencil8(int raw) => switch (_fbFormat) {
        1 => _stencilOf(raw) * 0xff,
        2 => _stencilOf(raw) * 0x11,
        _ => _stencilOf(raw),
      };

  int _stencilRaw(int value) => switch (_fbFormat) {
        1 => value << 15,
        2 => value << 12,
        3 => value << 24,
        _ => 0,
      };

  /// Applies a stencil operation (keep, zero, replace, invert,
  /// increment, decrement) at the format's width; the reference value
  /// is reduced to that width by its top bits.
  int _stencilOp(int op, int raw) {
    final value = _stencilOf(raw);
    final bits = const [0, 1, 4, 8][_fbFormat];
    final max = (1 << bits) - 1;
    switch (op) {
      case 1:
        return 0;
      case 2:
        return ((regs[0xdc] >> 8) & 0xff) >> (8 - bits);
      case 3:
        return max - value;
      case 4:
        return value < max ? value + 1 : max;
      case 5:
        return value > 0 ? value - 1 : 0;
      default:
        return value;
    }
  }

  /// Writes only the stencil after a failed stencil or depth test.
  void _writeStencil(int x, int y, int dstRaw, int op) {
    final alpha = _alphaMask;
    final out = (dstRaw & ~alpha) | _stencilRaw(_stencilOp(op, dstRaw));
    final keep = _keepMask;
    _writeRaw(x, y, (dstRaw & keep) | (out & ~keep));
  }

  bool _compare(int func, int value, int ref) {
    switch (func) {
      case 0:
        return false;
      case 1:
        return true;
      case 2:
        return value == ref;
      case 3:
        return value != ref;
      case 4:
        return value < ref;
      case 5:
        return value <= ref;
      case 6:
        return value > ref;
      default:
        return value >= ref;
    }
  }

  double _blendChannel(
      double src, double dst, double srcA, double dstA, int channel) {
    // The source factor sits in bits 0-3, the destination factor in bits
    // 4-7 and the equation in bits 8-11.
    final mode = regs[0xdf];
    final op = (mode >> 8) & 7;
    if (op == 3) return math.min(src, dst);
    if (op == 4) return math.max(src, dst);
    final sf = _blendFactor(mode & 0xf, dst, srcA, dstA, regs[0xe0], channel);
    final df =
        _blendFactor((mode >> 4) & 0xf, src, srcA, dstA, regs[0xe1], channel);
    switch (op) {
      case 1:
        return (src * sf - dst * df).clamp(0.0, 1.0);
      case 2:
        return (dst * df - src * sf).clamp(0.0, 1.0);
      case 5:
        return (src - dst).abs();
      default:
        return (src * sf + dst * df).clamp(0.0, 1.0);
    }
  }

  double _blendFactor(int factor, double other, double srcA, double dstA,
      int fixed, int channel) {
    switch (factor) {
      case 0: // the other side's color (or alpha)
        return other;
      case 1:
        return 1 - other;
      case 2:
        return srcA;
      case 3:
        return 1 - srcA;
      case 4:
        return dstA;
      case 5:
        return 1 - dstA;
      // The doubled alphas. How the hardware limits one minus a doubled
      // alpha above one half is unclear; it stays at zero here.
      case 6:
        return 2 * srcA;
      case 7:
        return math.max(0.0, 1 - 2 * srcA);
      case 8:
        return 2 * dstA;
      case 9:
        return math.max(0.0, 1 - 2 * dstA);
      case 10: // the fixed color's matching channel
        return (fixed >> (channel * 8) & 0xff) / 255;
      default:
        return 1;
    }
  }

  /// The mipmap level a draw samples. Only the constant mode of the
  /// texture level register selects one: its offset, a signed fixed point
  /// number with four fraction bits in bits 16..23, picks the level up to
  /// the maximum level of the texture mode. The automatic and slope modes
  /// sample level 0, without a level of detail. The rounding of a
  /// fractional offset is not checked against hardware.
  int _textureLevel() {
    final mode = regs[0xc8];
    if (mode & 3 != 1) return 0;
    final offset = ((mode >> 16) & 0xff).toSigned(8);
    final maxLevel = (regs[0xc2] >> 16) & 7;
    return ((offset + 8) >> 4).clamp(0, maxLevel);
  }

  List<double> _sample(_Vertex v) {
    final level = _textureLevel();
    final size = regs[0xb8 + level];
    final texW = 1 << (size & 0xff).clamp(0, 10);
    final texH = 1 << ((size >> 8) & 0xff).clamp(0, 10);
    var u = v.su, w = v.sv;
    if (v.invW != 0 && v.invW != 1) {
      u /= v.invW;
      w /= v.invW;
    }
    // Through vertices address texels directly; transformed ones use
    // normalized coordinates scaled by the texture size.
    final throughTex = regs[0x12] & 0x800000 != 0;
    // The scale and offset apply to the texture coordinate mapping of
    // transformed vertices only, not to the texture matrix, environment
    // mapping or the texel coordinates of through vertices.
    var tu = u, tv = w;
    if (!throughTex && regs[0xc0] & 3 == 0) {
      tu = u * PspGe._floatArg(regs[0x48]) + PspGe._floatArg(regs[0x4a]);
      tv = w * PspGe._floatArg(regs[0x49]) + PspGe._floatArg(regs[0x4b]);
    }
    if (!throughTex) {
      tu *= texW;
      tv *= texH;
    }
    final filter = regs[0xc6];
    final linear = ((filter >> 8) & 7) == 1 || (filter & 7) == 1;
    if (!linear) {
      return _texel(tu.floor(), tv.floor(), texW, texH, level);
    }
    final x = tu - 0.5, y = tv - 0.5;
    final x0 = x.floor(), y0 = y.floor();
    final fx = x - x0, fy = y - y0;
    final c00 = _texel(x0, y0, texW, texH, level);
    final c10 = _texel(x0 + 1, y0, texW, texH, level);
    final c01 = _texel(x0, y0 + 1, texW, texH, level);
    final c11 = _texel(x0 + 1, y0 + 1, texW, texH, level);
    return [
      for (var i = 0; i < 4; i++)
        (c00[i] * (1 - fx) + c10[i] * fx) * (1 - fy) +
            (c01[i] * (1 - fx) + c11[i] * fx) * fy
    ];
  }

  List<double> _texel(int x, int y, int texW, int texH, int level) {
    final wrap = regs[0xc7];
    x = (wrap & 0xff) == 1 ? x.clamp(0, texW - 1) : ((x % texW) + texW) % texW;
    y = ((wrap >> 8) & 0xff) == 1
        ? y.clamp(0, texH - 1)
        : ((y % texH) + texH) % texH;
    final format = regs[0xc3] & 0xf;
    final bufWidth = regs[0xa8 + level] & 0xffff;
    final pitch = bufWidth == 0 ? texW : bufWidth;
    final base = _addr(regs[0xa0 + level], regs[0xa8 + level]);
    final swizzled = regs[0xc2] & 1 != 0;
    int rgba;
    if (format >= 4 && format <= 7) {
      final index = _texelIndex(x, y, pitch, base, format, swizzled);
      final clut = regs[0xc5];
      final shift = (clut >> 2) & 0x1f, mask = (clut >> 8) & 0xff;
      final start = (clut >> 16) & 0xff;
      var at = ((index >> shift) & mask) + start;
      if (at >= _paletteCount) at = _paletteCount - 1;
      rgba = at < 0 ? 0 : _palette[at];
    } else if (format == 3) {
      rgba = mem.read32(base + _texelOffset(x, y, pitch, 4, swizzled));
    } else if (format <= 2) {
      final v = mem.read16(base + _texelOffset(x, y, pitch, 2, swizzled));
      rgba = PspGe._expand16(v, format);
    } else {
      rgba = 0xffffffff;
    }
    return [
      (rgba & 0xff) / 255,
      (rgba >> 8 & 0xff) / 255,
      (rgba >> 16 & 0xff) / 255,
      (rgba >> 24 & 0xff) / 255
    ];
  }

  int _texelIndex(
      int x, int y, int pitch, int base, int format, bool swizzled) {
    if (format == 5) {
      return mem.read8(base + _texelOffset(x, y, pitch, 1, swizzled));
    }
    if (format == 6) {
      return mem.read16(base + _texelOffset(x, y, pitch, 2, swizzled));
    }
    if (format == 7) {
      return mem.read32(base + _texelOffset(x, y, pitch, 4, swizzled));
    }
    // Two texels share a byte; a swizzled block is 32 texels wide.
    final byte =
        mem.read8(base + _texelOffset(x >> 1, y, pitch >> 1, 1, swizzled));
    return (x & 1) == 0 ? byte & 0xf : byte >> 4;
  }

  /// The byte offset of a texel inside its buffer, applying the block
  /// swizzle layout when the texture mode asks for it.
  int _texelOffset(int x, int y, int pitch, int bpp, bool swizzled) {
    final pitchBytes = pitch * bpp;
    if (swizzled) {
      // A block is 16 bytes wide even when a line is narrower, so a
      // narrow texture still steps its lines 16 bytes apart.
      final blockPitch = pitchBytes < 16 ? 16 : pitchBytes;
      final byteX = x * bpp;
      return ((y >> 3) * (blockPitch << 3)) +
          ((byteX >> 4) << 7) +
          ((y & 7) << 4) +
          (byteX & 15);
    }
    return y * pitchBytes + x * bpp;
  }

  int _encodePixel(double r, double g, double b, double a) =>
      _encodeBytes(
          (r.clamp(0.0, 1.0) * 255).round(),
          (g.clamp(0.0, 1.0) * 255).round(),
          (b.clamp(0.0, 1.0) * 255).round(),
          (a.clamp(0.0, 1.0) * 255).round());

  int _encodeBytes(int ri, int gi, int bi, int ai) {
    switch (_fbFormat) {
      case 0:
        return (ri >> 3) | (gi >> 2) << 5 | (bi >> 3) << 11;
      case 1:
        return (ri >> 3) |
            (gi >> 3) << 5 |
            (bi >> 3) << 10 |
            (ai >= 128 ? 0x8000 : 0);
      case 2:
        return (ri >> 4) | (gi >> 4) << 4 | (bi >> 4) << 8 | (ai >> 4) << 12;
      default:
        return ri | gi << 8 | bi << 16 | ai << 24;
    }
  }

  List<double> _decodePixel(int raw) {
    if (_fbFormat == 3) {
      return [
        (raw & 0xff) / 255,
        (raw >> 8 & 0xff) / 255,
        (raw >> 16 & 0xff) / 255,
        (raw >> 24 & 0xff) / 255
      ];
    }
    final v = PspGe._expand16(raw, _fbFormat);
    return [
      (v & 0xff) / 255,
      (v >> 8 & 0xff) / 255,
      (v >> 16 & 0xff) / 255,
      (v >> 24 & 0xff) / 255
    ];
  }

  int _readRaw(int x, int y) {
    final bpp = _fbFormat == 3 ? 4 : 2;
    final at = _fbAddr + (y * _fbWidth + x) * bpp;
    return bpp == 4 ? mem.read32(at) : mem.read16(at);
  }

  void _writeRaw(int x, int y, int value) {
    final bpp = _fbFormat == 3 ? 4 : 2;
    final at = _fbAddr + (y * _fbWidth + x) * bpp;
    if (bpp == 4) {
      mem.write32(at, value);
    } else {
      mem.write16(at, value);
    }
  }

  int _readDepth(int x, int y) => mem.read16(_zAddr + (y * _zWidth + x) * 2);

  void _writeDepth(int x, int y, int value) =>
      mem.write16(_zAddr + (y * _zWidth + x) * 2, value);
}
