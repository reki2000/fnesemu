import 'dart:math' as math;
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../../state.dart';
import '../../util/int.dart';

import 'bus.dart';

/// A colour with named channels, held as two vectors: red and green, then
/// blue and alpha. The combiner and the interpolation pass the vectors.
final class Rgba {
  Float64x2 rg, ba;
  Rgba([double r = 0, double g = 0, double b = 0, double a = 0])
      : rg = Float64x2(r, g),
        ba = Float64x2(b, a);

  /// Unpacks 0xRRGGBBAA.
  factory Rgba.fromWord(int v) => Rgba(v.shr24.mask8.toDouble(),
      v.shr16.mask8.toDouble(), v.shr8.mask8.toDouble(), v.mask8.toDouble());
  factory Rgba.read(StateReader s) {
    final v = s.floats();
    return Rgba(v[0], v[1], v[2], v[3]);
  }

  double get r => rg.x;
  double get g => rg.y;
  double get b => ba.x;
  double get a => ba.y;
  set r(double v) => rg = rg.withX(v);
  set g(double v) => rg = rg.withY(v);
  set b(double v) => ba = ba.withX(v);
  set a(double v) => ba = ba.withY(v);

  @pragma('vm:prefer-inline')
  void set(double red, double green, double blue, double alpha) {
    rg = Float64x2(red, green);
    ba = Float64x2(blue, alpha);
  }

  @pragma('vm:prefer-inline')
  void copy(Rgba o) {
    rg = o.rg;
    ba = o.ba;
  }

  void write(StateWriter w) => w.floats([r, g, b, a]);
}

final class Vec3 {
  double x, y, z;
  Vec3(this.x, this.y, this.z);
  factory Vec3.read(StateReader s) {
    final v = s.floats();
    return Vec3(v[0], v[1], v[2]);
  }
  void write(StateWriter w) => w.floats([x, y, z]);
}

/// A homogeneous clip-space position.
final class Vec4 {
  double x, y, z, w;
  Vec4(this.x, this.y, this.z, this.w);
  factory Vec4.read(StateReader s) {
    final v = s.floats();
    return Vec4(v[0], v[1], v[2], v[3]);
  }
  void write(StateWriter w) => w.floats([x, y, z, this.w]);
}

/// A directional light: the colour and the direction.
final class Light {
  double r = 0, g = 0, b = 0, dx = 0, dy = 0, dz = 0;

  void read(StateReader s) {
    final v = s.floats();
    r = v[0];
    g = v[1];
    b = v[2];
    dx = v[3];
    dy = v[4];
    dz = v[5];
  }

  void write(StateWriter w) => w.floats([r, g, b, dx, dy, dz]);
}

class N64Tile {
  int format = 0, size = 0, line = 0, tmem = 0, palette = 0;
  int sMode = 0, tMode = 0, sMask = 0, tMask = 0, sShift = 0, tShift = 0;
  double left = 0, top = 0, right = 0, bottom = 0;
}

class N64Vertex {
  final Vec4 clip;
  final Rgba color;
  final double s, t;
  N64Vertex(this.clip, this.color, this.s, this.t);
  N64Vertex mix(N64Vertex b, double f) => N64Vertex(
      Vec4(clip.x + (b.clip.x - clip.x) * f, clip.y + (b.clip.y - clip.y) * f,
          clip.z + (b.clip.z - clip.z) * f, clip.w + (b.clip.w - clip.w) * f),
      Rgba(
          color.r + (b.color.r - color.r) * f,
          color.g + (b.color.g - color.g) * f,
          color.b + (b.color.b - color.b) * f,
          color.a + (b.color.a - color.a) * f),
      s + (b.s - s) * f,
      t + (b.t - t) * f);
}

/// Independent Fast3D/F3DEX task decoder and software rasterizer.
/// Uses the documented GBI protocol; does not execute RSP instruction binaries.
class N64Graphics {
  final N64Bus bus;
  final segments = List<int>.filled(16, 0);
  final vertices = List<N64Vertex?>.filled(80, null);
  final tiles = List.generate(8, (_) => N64Tile());
  final tmem = Uint8List(4096);
  // Pixel scratch colours are consumed synchronously, never retained.
  final _shade = Rgba(), _tex = Rgba(), _out = Rgba();
  final _whiteColor = Rgba(255, 255, 255, 255);
  // Instance tables: a static final field is lazily initialized and checked on
  // every read, and int.toDouble() in a hot path can be a call.
  final _fiveBit =
      Float64List.fromList([for (var v = 0; v < 32; v++) v * 255 / 31]);
  final _byte = Float64List.fromList([for (var v = 0; v < 256; v++) v * 1.0]);
  // Multipliers of the tile coordinate shifts; powers of two, so exact.
  final _shiftScale = Float64List.fromList([
    for (var shift = 0; shift < 16; shift++)
      shift <= 10 ? 1 / (1 << shift) : (1 << (16 - shift)) * 1.0
  ]);
  void _textureRgba(double red, double green, double blue, double alpha) {
    _tex.set(red, green, blue, alpha);
  }

  void _texture16(int value) => _textureRgba(
      _fiveBit[value.shr11.mask5],
      _fiveBit[value.shr6.mask5],
      _fiveBit[value.shr1.mask5],
      value.mask1 * 255.0);

  final lights = List.generate(8, (_) => Light());
  Float64List model = identity(), projection = identity();
  final stack = <Float64List>[];
  Vec3 scale = Vec3(160, 120, 511), translate = Vec3(160, 120, 511);
  int geometry = 0, numLights = 1;
  int colorImage = 0, colorSize = 2, width = 320, zImage = 0;
  int textureImage = 0, textureSize = 2, textureWidth = 1, textureFormat = 0;
  int activeTile = 0;
  double textureS = 1, textureT = 1;
  bool textureOn = false;
  int otherHigh = 0, otherLow = 0, combine0 = 0, combine1 = 0, fillColor = 0;
  final primitive = Rgba(255, 255, 255, 255),
      environment = Rgba(255, 255, 255, 255),
      fog = Rgba();
  int scLeft = 0, scTop = 0, scRight = 320, scBottom = 240;
  int tasks = 0, triangles = 0;
  final depths = <int, Float64List>{};
  bool extended = false;
  // F3DEX2 / F3DZEX use a different opcode layout and geometry mode bits
  bool f3dex2 = false, _s2dex = false;
  int _half1 = 0;
  int geometry2 = 0;
  bool rasterize =
      true; // Optional headless fast-forward; normal execution renders every task.
  N64Graphics(this.bus);

  List<int> get _scalars => [
        geometry, numLights, colorImage, colorSize, width, zImage, //
        textureImage, textureSize, textureWidth, textureFormat, activeTile,
        otherHigh, otherLow, combine0, combine1, fillColor, //
        scLeft, scTop, scRight, scBottom, tasks, triangles, geometry2
      ];

  /// Saves the decoder state between tasks; [rasterize] is configuration.
  void saveState(StateWriter w) {
    w.section('graphics');
    w.ints(segments);
    for (final v in vertices) {
      w.boolean(v != null);
      if (v == null) continue;
      v.clip.write(w);
      v.color.write(w);
      w.float64(v.s);
      w.float64(v.t);
    }
    for (final t in tiles) {
      w.ints([
        t.format, t.size, t.line, t.tmem, t.palette, t.sMode, t.tMode, //
        t.sMask, t.tMask, t.sShift, t.tShift
      ]);
      w.floats([t.left, t.top, t.right, t.bottom]);
    }
    w.bytes(tmem);
    for (final light in lights) {
      light.write(w);
    }
    w.floats(model);
    w.floats(projection);
    w.int32(stack.length);
    stack.forEach(w.floats);
    scale.write(w);
    translate.write(w);
    for (final v in [primitive, environment, fog]) {
      v.write(w);
    }
    w.ints(_scalars);
    w.floats([textureS, textureT]);
    for (final b in [textureOn, extended, f3dex2]) {
      w.boolean(b);
    }
    w.boolean(_s2dex);
    w.int32(_half1);
    w.int32(depths.length);
    for (final MapEntry(:key, :value) in depths.entries) {
      w.int64(key);
      w.floats(value);
    }
  }

  void loadState(StateReader s) {
    s.section('graphics');
    s.intsInto(segments);
    for (var i = 0; i < vertices.length; i++) {
      vertices[i] = s.boolean()
          ? N64Vertex(Vec4.read(s), Rgba.read(s), s.float64(), s.float64())
          : null;
    }
    for (final t in tiles) {
      final v = s.ints(), f = s.floats();
      var i = 0;
      t.format = v[i++];
      t.size = v[i++];
      t.line = v[i++];
      t.tmem = v[i++];
      t.palette = v[i++];
      t.sMode = v[i++];
      t.tMode = v[i++];
      t.sMask = v[i++];
      t.tMask = v[i++];
      t.sShift = v[i++];
      t.tShift = v[i++];
      t.left = f[0];
      t.top = f[1];
      t.right = f[2];
      t.bottom = f[3];
    }
    s.bytesInto(tmem);
    for (final light in lights) {
      light.read(s);
    }
    model = Float64List.fromList(s.floats());
    projection = Float64List.fromList(s.floats());
    stack
      ..clear()
      ..addAll([
        for (var n = s.int32(); n > 0; n--) Float64List.fromList(s.floats())
      ]);
    scale = Vec3.read(s);
    translate = Vec3.read(s);
    primitive.copy(Rgba.read(s));
    environment.copy(Rgba.read(s));
    fog.copy(Rgba.read(s));
    final v = s.ints();
    if (v.length != _scalars.length) {
      throw const StateMismatch('graphics state layout');
    }
    var i = 0;
    geometry = v[i++];
    numLights = v[i++];
    colorImage = v[i++];
    colorSize = v[i++];
    width = v[i++];
    zImage = v[i++];
    textureImage = v[i++];
    textureSize = v[i++];
    textureWidth = v[i++];
    textureFormat = v[i++];
    activeTile = v[i++];
    otherHigh = v[i++];
    otherLow = v[i++];
    combine0 = v[i++];
    combine1 = v[i++];
    fillColor = v[i++];
    scLeft = v[i++];
    scTop = v[i++];
    scRight = v[i++];
    scBottom = v[i++];
    tasks = v[i++];
    triangles = v[i++];
    geometry2 = v[i++];
    final f = s.floats();
    textureS = f[0];
    textureT = f[1];
    textureOn = s.boolean();
    extended = s.boolean();
    f3dex2 = s.boolean();
    _s2dex = s.boolean();
    _half1 = s.int32();
    depths.clear();
    for (var n = s.int32(); n > 0; n--) {
      final key = s.int64();
      depths[key] = Float64List.fromList(s.floats());
    }
  }

  static Float64List identity() =>
      Float64List.fromList([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]);
  void reset() {
    tasks = triangles = 0;
    segments.fillRange(0, 16, 0);
    vertices.fillRange(0, 80, null);
    model = identity();
    projection = identity();
    stack.clear();
    depths.clear();
    tmem.fillRange(0, tmem.length, 0);
    for (var i = 0; i < tiles.length; i++) {
      tiles[i] = N64Tile();
    }
    for (final light in lights) {
      light
        ..r = 0
        ..g = 0
        ..b = 0
        ..dx = 0
        ..dy = 0
        ..dz = 0;
    }
    scale = Vec3(160, 120, 511);
    translate = Vec3(160, 120, 511);
    geometry = 0;
    numLights = 1;
    colorImage = zImage = textureImage = 0;
    width = 320;
    colorSize = textureSize = 2;
    textureWidth = 1;
    textureFormat = activeTile = 0;
    textureS = textureT = 1;
    textureOn = false;
    otherHigh = otherLow = combine0 = combine1 = fillColor = 0;
    primitive.set(255, 255, 255, 255);
    environment.set(255, 255, 255, 255);
    fog.set(0, 0, 0, 0);
    scLeft = scTop = 0;
    scRight = 320;
    scBottom = 240;
    extended = false;
    f3dex2 = _s2dex = false;
    _half1 = 0;
    geometry2 = 0;
  }

  int resolve(int addr) =>
      (addr.mask24 + segments[addr.shr24.mask4]) & 0x7fffff;
  int u(int addr, int size) => bus.ramRead(addr, size);
  double signed(int addr, int size) =>
      u(addr, size).toSigned(size * 8).toDouble();
  Float64List matrix(int addr) {
    final m = Float64List(16);
    for (var i = 0; i < 16; i++) {
      m[i] = signed(addr + i * 2, 2) + u(addr + 32 + i * 2, 2) / 65536;
    }
    return m;
  }

  // Sums run left to right, as a reduce over the four products would.
  Float64List multiply(Float64List a, Float64List b) {
    final m = Float64List(16);
    for (var row = 0; row < 4; row++) {
      final r = row * 4;
      for (var col = 0; col < 4; col++) {
        m[r + col] = a[r] * b[col] +
            a[r + 1] * b[4 + col] +
            a[r + 2] * b[8 + col] +
            a[r + 3] * b[12 + col];
      }
    }
    return m;
  }

  Vec4 transform(double x, double y, double z, double w, Float64List m) => Vec4(
      x * m[0] + y * m[4] + z * m[8] + w * m[12],
      x * m[1] + y * m[5] + z * m[9] + w * m[13],
      x * m[2] + y * m[6] + z * m[10] + w * m[14],
      x * m[3] + y * m[7] + z * m[11] + w * m[15]);

  void _viewport(int addr) {
    scale = Vec3(
        signed(addr, 2) / 4, signed(addr + 2, 2) / 4, signed(addr + 4, 2) / 4);
    translate = Vec3(signed(addr + 8, 2) / 4, signed(addr + 10, 2) / 4,
        signed(addr + 12, 2) / 4);
  }

  void _light(Light l, int addr) {
    l.r = u(addr, 1).toDouble();
    l.g = u(addr + 1, 1).toDouble();
    l.b = u(addr + 2, 1).toDouble();
    l.dx = signed(addr + 8, 1) / 127;
    l.dy = signed(addr + 9, 1) / 127;
    l.dz = signed(addr + 10, 1) / 127;
  }

  void task(int address, int size, int ucodeData, int ucodeSize) {
    _selectMicrocode(ucodeData, ucodeSize);
    tasks++;
    displayList(address);
  }

  void _selectMicrocode(int ucodeData, int ucodeSize) {
    final end = math.min(bus.ram.length, ucodeData + math.min(ucodeSize, 2048));
    final text = String.fromCharCodes(bus.ram.sublist(ucodeData, end.toInt()));
    final start = text.indexOf('RSP Gfx ucode');
    final name = start < 0 ? text : text.substring(start).split('\x00').first;
    _s2dex = name.contains('S2DEX');
    // F3DEX2 microcodes are named F3DEX2 / F3DZEX, or "RSP Gfx ucode <name>
    // ... 2.xx" (F3DEX, F3DLX, F3DFLX, L3DEX, ...)
    final version =
        RegExp(r'RSP Gfx ucode [A-Z0-9.]+[^0-9]*(\d)\.\d').firstMatch(name);
    f3dex2 = name.contains('F3DEX2') ||
        name.contains('F3DZEX') ||
        name.contains('F3DLX2') ||
        version?.group(1) == '2';
    extended = f3dex2 || name.contains('F3DEX') || name.contains('F3DLP');
  }

  void displayList(int address) {
    var pc = address & 0x7fffff;
    final returns = <int>[];
    for (var commands = 0; commands < 100000; commands++) {
      final w0 = u(pc, 4), w1 = u(pc + 4, 4), op = w0.shr24;
      pc += 8;
      if (_s2dex && (op == 0x09 || op == 0x0a)) {
        _background(resolve(w1), scaled: op == 0x09);
        continue;
      }
      if (_s2dex && op == 0x0b) {
        // Object render flags affect sprites; backgrounds use the RDP modes.
        continue;
      }
      if (f3dex2) {
        var handled = true;
        switch (op) {
          case 0x00 || 0x02 || 0x03 || 0x04 || 0x08:
            break; // NOOP, MODIFYVTX, CULLDL, BRANCH_Z, LINE3D are not needed
          case 0x01:
            final n = w0.shr12.mask8, end = w0.shr1.mask7;
            _loadVertices(resolve(w1), end - n, n);
          case 0x05:
            drawIndices(w0, 2);
          case 0x06 || 0x07:
            drawIndices(w0, 2);
            drawIndices(w1, 2);
          case 0xd7:
            activeTile = w0.shr8.mask3;
            textureOn = w0.shr1.mask7 != 0;
            textureS = w1.shr16.mask16 / 65536;
            textureT = w1.mask16 / 65536;
          case 0xd8:
            for (var i = 0; i < w1 ~/ 64; i++) {
              if (stack.isNotEmpty) model = stack.removeLast();
            }
          case 0xd9:
            // w0 holds the inverted clear mask, w1 the bits to set
            geometry2 = (geometry2 & w0.mask24) | w1;
            geometry = (geometry2.bit0 ? 1 : 0) |
                (geometry2.bit9 ? 0x1000 : 0) |
                (geometry2.bit10 ? 0x2000 : 0) |
                (geometry2.bit17 ? 0x20000 : 0);
          case 0xda:
            final flags = w0.mask8 ^ 1, m = matrix(resolve(w1));
            if (flags.bit2) {
              projection = flags.bit1 ? m : multiply(m, projection);
            } else {
              if (flags.bit0) {
                if (stack.length >= 32) {
                  throw StateError('RSP matrix stack overflow');
                }
                stack.add(Float64List.fromList(model));
              }
              model = flags.bit1 ? m : multiply(m, model);
            }
          case 0xdb:
            final index = w0.shr16.mask8, offset = w0.mask16;
            if (index == 0x06) {
              segments[(offset ~/ 4).mask4] = w1.mask24;
            } else if (index == 0x02) {
              numLights = w1 ~/ 24;
            }
          case 0xdc:
            final index = w0.mask8, offset = w0.shr8.mask8 * 8;
            final addr = resolve(w1);
            if (index == 8) {
              _viewport(addr);
            } else if (index == 10) {
              _light(lights[(offset ~/ 24 - 2).clamp(0, 7)], addr);
            }
          case 0xde:
            if (w0.shr16.mask8 == 0) {
              if (returns.length >= 64) {
                throw StateError('RSP display list stack overflow');
              }
              returns.add(pc);
            }
            pc = resolve(w1);
          case 0xdf:
            if (returns.isEmpty) return;
            pc = returns.removeLast();
          case 0xe1:
            _half1 = w1;
          case 0xdd:
            _selectMicrocode(resolve(_half1), w0.mask16 + 1);
          case 0xd6 || 0xe0:
            // DMA_IO, SPNOOP. DMA_IO moves data
            // between the DMEM of the microcode and RDRAM, which this HLE
            // does not have.
            break;
          case 0xe2 || 0xe3:
            // the field is addressed from the top bit: shift = 32 - ofs - len
            final length = w0.mask8 + 1, shift = 32 - w0.shr8.mask8 - length;
            final mask = (((1 << length) - 1) << shift).mask32;
            if (op == 0xe2) {
              otherLow = (otherLow & ~mask) | (w1 & mask);
            } else {
              otherHigh = (otherHigh & ~mask) | (w1 & mask);
            }
          default:
            handled = false;
        }
        if (handled) continue;
      }
      switch (op) {
        case 0:
          break;
        case 1:
          final flags = w0.shr16.mask8, m = matrix(resolve(w1));
          if (flags.bit0) {
            projection = flags.bit1 ? m : multiply(m, projection);
          } else {
            if (flags.bit2) {
              if (stack.length >= 32) {
                throw StateError('RSP matrix stack overflow');
              }
              stack.add(Float64List.fromList(model));
            }
            model = flags.bit1 ? m : multiply(m, model);
          }
        case 3:
          final index = w0.shr16.mask8, addr = resolve(w1);
          if (index == 0x80) {
            _viewport(addr);
          } else if (index >= 0x86 && index <= 0x94) {
            _light(lights[(index - 0x86) ~/ 2], addr);
          } else if (index != 0x82 && index != 0x84) {
            throw UnsupportedError('RSP MOVEMEM $index');
          }
        case 4:
          final count = extended ? w0.shr10.mask6 : w0.shr20.mask4 + 1;
          final first = extended ? w0.shr17.mask7 : w0.shr16.mask4;
          _loadVertices(resolve(w1), first, count);
        case 6:
          if (w0.shr16.mask8 == 0) {
            if (returns.length >= 64) {
              throw StateError('RSP display list stack overflow');
            }
            returns.add(pc);
          }
          pc = resolve(w1);
        case 0xb8:
          if (returns.isEmpty) return;
          pc = returns.removeLast();
        case 0xbd:
          if (stack.isNotEmpty) model = stack.removeLast();
        case 0xbc:
          final index = w0.mask8, offset = w0.shr8.mask16;
          if (index == 6) {
            segments[(offset ~/ 4).mask4] = w1.mask24;
          } else if (index == 2) {
            numLights = extended ? w1 ~/ 24 : ((w1 & 0x7fffffff) ~/ 32 - 1);
          } else if (index == 10) {
            final l = lights[(offset ~/ 32).clamp(0, 7)];
            l.r = w1.shr24.mask8.toDouble();
            l.g = w1.shr16.mask8.toDouble();
            l.b = w1.shr8.mask8.toDouble();
          } else if (![0, 4, 8, 14].contains(index)) {
            throw UnsupportedError('RSP MOVEWORD $index');
          }
        case 0xbb:
          activeTile = w0.shr8.mask3;
          textureOn = w0.mask8 != 0;
          textureS = w1.shr16.mask16 / 65536;
          textureT = w1.mask16 / 65536;
        case 0xb7:
          geometry |= w1;
        case 0xb6:
          geometry &= ~w1;
        case 0xba:
          final shift = w0.shr8.mask8, length = w0.mask8;
          final mask = ((1 << length) - 1).shl(shift);
          otherHigh = (otherHigh & ~mask) | (w1 & mask);
        case 0xb9:
          final shift = w0.shr8.mask8, length = w0.mask8;
          final mask = ((1 << length) - 1).shl(shift);
          otherLow = (otherLow & ~mask) | (w1 & mask);
        case 0xbf:
          drawIndices(w1, extended ? 2 : 10);
        case 0xb1:
          drawIndices(w0, 2);
          drawIndices(w1, 2);
        case 0xbe:
          break; // CULLDL is an optional visibility optimization.
        case 0xb4:
          break;
        case 0xb3:
          break;
        case 0xb2:
          final index = (w0.mask16 ~/ 2).clamp(0, 79), v = vertices[index];
          if (v != null && w0.shr16.mask8 == 0x10) {
            vertices[index] = N64Vertex(v.clip, Rgba.fromWord(w1), v.s, v.t);
          }
        case 0xe4:
        case 0xe5:
          final st = u(pc + 4, 4), delta = u(pc + 12, 4);
          pc += 16;
          textureRect(w0, w1, st, delta, op == 0xe5);
        default:
          if (op >= 0xe6) {
            rdp(w0, w1);
          } else {
            throw UnsupportedError(
                'RSP GBI opcode 0x${op.hex} at 0x${(pc - 8).hex}: ${w0.hex} ${w1.hex}');
          }
      }
    }
    throw StateError('RSP display list exceeded command budget');
  }

  // S2DEX backgrounds sample a DRAM image directly, bypassing the small TMEM
  // strips emitted by the microcode. Coordinates follow uObj[Scale]Bg.
  void _background(int address, {required bool scaled}) {
    if (!rasterize) return;
    final imageWidth = u(address + 2, 2) >> 2;
    final imageHeight = u(address + 10, 2) >> 2;
    if (imageWidth == 0 || imageHeight == 0) return;
    final format = u(address + 22, 1), size = u(address + 23, 1);
    if (format != 0 || (size != 2 && size != 3)) {
      throw UnsupportedError('S2DEX background format $format/$size');
    }
    final source = resolve(u(address + 16, 4));
    final x0 = signed(address + 4, 2) / 4;
    final y0 = signed(address + 12, 2) / 4;
    final frameWidth = u(address + 6, 2) / 4;
    final frameHeight = u(address + 14, 2) / 4;
    final imageX = u(address, 2) / 32;
    final imageY = u(address + 8, 2) / 32;
    final scaleX = scaled ? u(address + 28, 2) / 1024 : 1.0;
    final scaleY = scaled ? u(address + 30, 2) / 1024 : 1.0;
    final flip = u(address + 26, 2).bit0;
    final bytes = size == 3 ? 4 : 2;
    final yEnd = math.min(math.min(scBottom, 576), y0 + frameHeight),
        xBegin = math.max(scLeft, math.max(0, x0.ceil())),
        xEnd = math.min(math.min(scRight, width), x0 + frameWidth);
    // The source column of every x is the same for each row.
    final columns = <int>[
      for (var x = xBegin; x < xEnd; x++)
        (imageX + (flip ? frameWidth - 1 - (x - x0) : x - x0) * scaleX)
                .floor() %
            imageWidth
    ];
    final destSize = colorSize == 3 ? 4 : 2, ramLength = bus.ram.length;
    final cache = size == 2;
    if (cache) _backgroundCache();
    final ramData = bus.ramData;
    for (var y = math.max(scTop, math.max(0, y0.ceil())); y < yEnd; y++) {
      final sy = (imageY + (y - y0) * scaleY).floor() % imageHeight;
      final rowBase = source + sy * imageWidth * bytes;
      for (var x = xBegin; x < xEnd; x++) {
        final value = u(rowBase + columns[x - xBegin] * bytes, bytes);
        if (cache) {
          var state = _lutState[value];
          if (state == 0) {
            _texture16(value);
            final c = _combine(_whiteColor, _tex);
            final r = c.r, g = c.g, b = c.b, a = c.a;
            if (a < 1) {
              state = 2;
            } else if (otherLow.bit14 && a < 255) {
              state = 3;
            } else {
              state = 1;
              _lutColor[value] = _pack(r, g, b, destSize);
            }
            _lutState[value] = state;
          }
          if (state == 2) continue;
          if (state == 1) {
            final at = colorImage + (y * width + x) * destSize;
            if (at + destSize > ramLength) continue;
            if (destSize == 4) {
              ramData.setUint32(at & 0x7fffff, _lutColor[value]);
            } else {
              ramData.setUint16(at & 0x7fffff, _lutColor[value]);
            }
            continue;
          }
        }
        if (size == 2) {
          _texture16(value);
        } else {
          _textureRgba(
              value.shr24.mask8.toDouble(),
              value.shr16.mask8.toDouble(),
              value.shr8.mask8.toDouble(),
              value.mask8.toDouble());
        }
        _put(x, y, _combine(_whiteColor, _tex));
      }
    }
  }

  // Memo of 16-bit texel -> packed output of a background, valid while the
  // blender and combiner state stays the same. States: 0 unknown, 1 plain
  // write, 2 rejected, 3 blended with the framebuffer (not memoized).
  final _lutState = Uint8List(65536), _lutColor = Uint32List(65536);
  final _lutKey = Float64List(13)..fillRange(0, 13, -1);

  /// Resets the memo when the state it depends on changed.
  void _backgroundCache() {
    final key = [
      combine0.toDouble(),
      combine1.toDouble(),
      otherHigh.toDouble(),
      otherLow.bit14 ? 1.0 : 0.0,
      colorSize.toDouble(),
      primitive.r,
      primitive.g,
      primitive.b,
      primitive.a,
      environment.r,
      environment.g,
      environment.b,
      environment.a,
    ];
    var same = true;
    for (var i = 0; i < key.length; i++) {
      if (_lutKey[i] != key[i]) {
        same = false;
        _lutKey[i] = key[i];
      }
    }
    if (!same) _lutState.fillRange(0, 65536, 0);
  }

  void _loadVertices(int addr, int first, int count) {
    final combined = multiply(model, projection);
    if (first + count > vertices.length) {
      throw StateError('RSP vertex buffer overflow');
    }
    final lightCount = numLights.clamp(0, 7);
    for (var i = 0; i < count; i++) {
      final p = addr + i * 16;
      final clip = transform(
          signed(p, 2), signed(p + 2, 2), signed(p + 4, 2), 1, combined);
      final color = Rgba(u(p + 12, 1).toDouble(), u(p + 13, 1).toDouble(),
          u(p + 14, 1).toDouble(), u(p + 15, 1).toDouble());
      if (geometry.bit17) {
        final nx = signed(p + 12, 1) / 127,
            ny = signed(p + 13, 1) / 127,
            nz = signed(p + 14, 1) / 127;
        var x = nx * model[0] + ny * model[4] + nz * model[8],
            y = nx * model[1] + ny * model[5] + nz * model[9],
            z = nx * model[2] + ny * model[6] + nz * model[10];
        final length = math.sqrt(((0.0 + x * x) + y * y) + z * z);
        if (length > 0) {
          x /= length;
          y /= length;
          z /= length;
        }
        final ambient = lights[lightCount];
        var red = ambient.r, green = ambient.g, blue = ambient.b;
        for (var l = 0; l < lightCount; l++) {
          final light = lights[l];
          final dot = math.max(0.0, x * light.dx + y * light.dy + z * light.dz);
          red += light.r * dot;
          green += light.g * dot;
          blue += light.b * dot;
        }
        color
          ..r = red
          ..g = green
          ..b = blue;
      }
      vertices[first + i] = N64Vertex(clip, color,
          signed(p + 8, 2) / 32 * textureS, signed(p + 10, 2) / 32 * textureT);
    }
  }

  void drawIndices(int word, int divisor) {
    if (!rasterize) return;
    final indices = [word.shr16.mask8, word.shr8.mask8, word.mask8]
        .map((v) => v ~/ divisor)
        .toList();
    if (indices.any((i) => i >= vertices.length || vertices[i] == null)) {
      throw StateError('RSP triangle uses unloaded vertex');
    }
    var polygon = indices.map((i) => vertices[i]!).toList();
    for (var plane = 0; plane < 6; plane++) {
      double distance(N64Vertex v) {
        final c = v.clip;
        final axis = switch (plane ~/ 2) { 0 => c.x, 1 => c.y, _ => c.z };
        return c.w + (plane.isEven ? axis : -axis);
      }

      final output = <N64Vertex>[];
      for (var i = 0; i < polygon.length; i++) {
        final a = polygon[i], b = polygon[(i + 1) % polygon.length];
        final da = distance(a), db = distance(b);
        if (da >= 0) output.add(a);
        if ((da >= 0) != (db >= 0)) output.add(a.mix(b, da / (da - db)));
      }
      polygon = output;
      if (polygon.length < 3) return;
    }
    for (var i = 1; i + 1 < polygon.length; i++) {
      triangle(polygon[0], polygon[i], polygon[i + 1]);
    }
  }

  Float64List get depth => depths.putIfAbsent(zImage,
      () => Float64List(640 * 576)..fillRange(0, 640 * 576, double.infinity));
  static double _edge(
          double ax, double ay, double bx, double by, double px, double py) =>
      (px - ax) * (by - ay) - (py - ay) * (bx - ax);

  void triangle(N64Vertex a, N64Vertex b, N64Vertex c) {
    if (!rasterize) return;
    final ca = a.clip, cb = b.clip, cc = c.clip;
    final wA = ca.w, wB = cb.w, wC = cc.w;
    if (wA.abs() < 1e-9 || wB.abs() < 1e-9 || wC.abs() < 1e-9) return;
    final i0 = 1 / wA, i1 = 1 / wB, i2 = 1 / wC;
    final sx = scale.x, sy = scale.y, sz = scale.z;
    final tx = translate.x, ty = translate.y, tz = translate.z;
    final x0 = ca.x * i0 * sx + tx,
        x1 = cb.x * i1 * sx + tx,
        x2 = cc.x * i2 * sx + tx;
    final y0 = -ca.y * i0 * sy + ty,
        y1 = -cb.y * i1 * sy + ty,
        y2 = -cc.y * i2 * sy + ty;
    final z0 = ca.z * i0 * sz + tz,
        z1 = cb.z * i1 * sz + tz,
        z2 = cc.z * i2 * sz + tz;
    final area = _edge(x0, y0, x1, y1, x2, y2);
    if (area.abs() < 1e-8) return;
    if ((geometry.bit13 && area < 0) || (geometry.bit12 && area > 0)) {
      return;
    }
    triangles++;
    final minX = math.max(scLeft, math.min(x0, math.min(x1, x2)).floor()),
        maxX = math.min(math.min(scRight, width) - 1,
            math.max(x0, math.max(x1, x2)).ceil());
    final minY = math.max(scTop, math.min(y0, math.min(y1, y2)).floor()),
        maxY = math.min(
            math.min(scBottom, 576) - 1, math.max(y0, math.max(y1, y2)).ceil());
    final depthBuffer = depth;
    final invArea = 1 / area;
    final waStep = (y2 - y1) * invArea,
        wbStep = (y0 - y2) * invArea,
        wcStep = -waStep - wbStep;
    // Infinite for a zero step, which the row narrowing does not read.
    final invWaStep = 1 / waStep,
        invWbStep = 1 / wbStep,
        invWcStep = 1 / wcStep;
    // The interpolants travel as four vectors: red and green, blue and alpha,
    // s and t, depth and 1/w.
    final rg0 = a.color.rg, rg1 = b.color.rg, rg2 = c.color.rg;
    final ba0 = a.color.ba, ba1 = b.color.ba, ba2 = c.color.ba;
    final st0 = Float64x2(a.s * i0, a.t * i0),
        st1 = Float64x2(b.s * i1, b.t * i1),
        st2 = Float64x2(c.s * i2, c.t * i2);
    final zi0 = Float64x2(z0, i0),
        zi1 = Float64x2(z1, i1),
        zi2 = Float64x2(z2, i2);
    final vaStep = Float64x2.splat(waStep),
        vbStep = Float64x2.splat(wbStep),
        vcStep = Float64x2.splat(wcStep);
    final rgStep = vaStep * rg0 + vbStep * rg1 + vcStep * rg2,
        baStep = vaStep * ba0 + vbStep * ba1 + vcStep * ba2,
        stStep = vaStep * st0 + vbStep * st1 + vcStep * st2,
        ziStep = vaStep * zi0 + vbStep * zi1 + vcStep * zi2;
    final depthTest = geometry.bit0 && otherLow.bit4,
        depthWrite = geometry.bit0 && otherLow.bit5;
    for (var py = minY; py <= maxY; py++) {
      // Narrow the row to the pixels that can be covered (a weight w + step * k
      // must reach zero within the edge tolerance), with a margin of one pixel;
      // the per-pixel coverage test below stays authoritative.
      final wa0 = _edge(x1, y1, x2, y2, minX + 0.5, py + 0.5) * invArea,
          wb0 = _edge(x2, y2, x0, y0, minX + 0.5, py + 0.5) * invArea;
      var first = 0, last = maxX - minX;
      if (waStep > 0) {
        first = math.max(first, ((-1e-9 - wa0) * invWaStep).floor() - 1);
      } else if (waStep < 0) {
        last = math.min(last, ((wa0 + 1e-9) * -invWaStep).ceil() + 1);
      } else if (wa0 < -1e-9) {
        last = -1;
      }
      if (wbStep > 0) {
        first = math.max(first, ((-1e-9 - wb0) * invWbStep).floor() - 1);
      } else if (wbStep < 0) {
        last = math.min(last, ((wb0 + 1e-9) * -invWbStep).ceil() + 1);
      } else if (wb0 < -1e-9) {
        last = -1;
      }
      final wc0 = 1 - wa0 - wb0;
      if (wcStep > 0) {
        first = math.max(first, ((-1e-9 - wc0) * invWcStep).floor() - 1);
      } else if (wcStep < 0) {
        last = math.min(last, ((wc0 + 1e-9) * -invWcStep).ceil() + 1);
      } else if (wc0 < -1e-9) {
        last = -1;
      }
      if (first > last) continue;
      final startX = minX + first, endX = minX + last;
      var wa = first == 0
              ? wa0
              : _edge(x1, y1, x2, y2, startX + 0.5, py + 0.5) * invArea,
          wb = first == 0
              ? wb0
              : _edge(x2, y2, x0, y0, startX + 0.5, py + 0.5) * invArea;
      final wc = 1 - wa - wb;
      final va = Float64x2.splat(wa),
          vb = Float64x2.splat(wb),
          vc = Float64x2.splat(wc);
      var rg = va * rg0 + vb * rg1 + vc * rg2,
          ba = va * ba0 + vb * ba1 + vc * ba2,
          st = va * st0 + vb * st1 + vc * st2,
          zi = va * zi0 + vb * zi1 + vc * zi2;
      for (var px = startX;
          px <= endX;
          px++,
          wa += waStep,
          wb += wbStep,
          rg += rgStep,
          ba += baStep,
          st += stStep,
          zi += ziStep) {
        // Re-evaluate coverage near an edge: accumulated roundoff must not
        // introduce cracks in adjacent triangles sharing that edge.
        // Clearly inside needs no exact test. This is the whole path except
        // within 1e-10 of an edge, and gives the same answer as the full test.
        final wc = 1 - wa - wb;
        var inside = true;
        if (!(wa > 1e-10 && wb > 1e-10 && wc > 1e-10)) {
          inside = wa >= 0 && wb >= 0 && wc >= 0;
          if (wa.abs() < 1e-10 || wb.abs() < 1e-10 || wc.abs() < 1e-10) {
            final exactA = _edge(x1, y1, x2, y2, px + 0.5, py + 0.5) * invArea,
                exactB = _edge(x2, y2, x0, y0, px + 0.5, py + 0.5) * invArea;
            inside = exactA >= 0 && exactB >= 0 && 1 - exactA - exactB >= 0;
          }
        }
        if (!inside) continue;
        final at = py * width + px;
        if (depthTest && zi.x > depthBuffer[at]) {
          continue;
        }
        _shade
          ..rg = rg
          ..ba = ba;
        if (textureOn) _texel(activeTile, st / Float64x2.splat(zi.y));
        final written =
            _put(px, py, _combine(_shade, textureOn ? _tex : _whiteColor));
        // Rejected transparent texels must not occlude later geometry.
        if (written && depthWrite) depthBuffer[at] = zi.x;
      }
    }
  }

  /// Test inspection returns a snapshot; the rasterizer uses private scratch.
  @visibleForTesting
  Rgba texel(int index, double s, double t) {
    _texel(index, Float64x2(s, t));
    return Rgba()..copy(_tex);
  }

  @visibleForTesting
  Rgba combine(Rgba shade, Rgba texture) =>
      Rgba()..copy(_combine(shade, texture));

  int _coordinate(
      double value, double low, double high, int shift, int mode, int mask) {
    var coord = (value * _shiftScale[shift] - low).floor();
    if (mode.bit1) {
      final extent = (high - low).floor(), limit = extent > 0 ? extent : 0;
      coord = coord < 0 ? 0 : (coord > limit ? limit : coord);
    }
    if (mask != 0) {
      final period = 1 << mask;
      if (mode.bit0 && coord & period != 0) {
        coord = period - 1 - (coord & (period - 1));
      } else {
        coord &= period - 1;
      }
    }
    return coord;
  }

  /// Writes the texel into [_tex].
  void _texel(int index, Float64x2 st) {
    final tile = tiles[index];
    final x = _coordinate(
            st.x, tile.left, tile.right, tile.sShift, tile.sMode, tile.sMask),
        y = _coordinate(
            st.y, tile.top, tile.bottom, tile.tShift, tile.tMode, tile.tMask);
    final row = tile.line * 8;
    final offset = (tile.tmem * 8 + y * row + x * (4 << tile.size) ~/ 8).mask12;
    var v = tmem[offset];
    if (tile.size == 0) v = (x.isEven ? v.shr4 : v).mask4;
    if (tile.size >= 2) v = v.shl8 | tmem[(offset + 1).mask12];
    if (tile.size == 3) {
      v = v.shl16 | tmem[(offset + 2).mask12].shl8 | tmem[(offset + 3).mask12];
    }
    if (tile.format == 0) {
      if (tile.size == 3) {
        _textureRgba(_byte[v.shr24.mask8], _byte[v.shr16.mask8],
            _byte[v.shr8.mask8], _byte[v.mask8]);
      } else {
        _texture16(v);
      }
      return;
    }
    if (tile.format == 2) {
      final paletteIndex = tile.size == 0 ? tile.palette * 16 + v : v;
      final p = (2048 + paletteIndex * 8).mask12;
      _texture16(tmem[p].shl8 | tmem[p + 1]);
      return;
    }
    if (tile.format == 3) {
      if (tile.size == 2) {
        final intensity = _byte[v.shr8.mask8];
        _textureRgba(intensity, intensity, intensity, _byte[v.mask8]);
        return;
      }
      final intensity = tile.size == 1 ? v.shr4 * 17 : v.shr1.mask3 * 255 / 7,
          alpha = tile.size == 1 ? v.mask4 * 17 : v.mask1 * 255;
      _textureRgba(intensity.toDouble(), intensity.toDouble(),
          intensity.toDouble(), alpha.toDouble());
      return;
    }
    final intensity = tile.size == 0 ? v * 17 : v;
    _textureRgba(intensity.toDouble(), intensity.toDouble(),
        intensity.toDouble(), intensity.toDouble());
  }

  static const _inv255 = 1 / 255;

  // RGB equation: (A - B) * C * (1 / 255) + D. C has alpha selectors too.
  static const _rgbInputA = 0, _rgbInputB = 1, _rgbInputC = 2, _rgbInputD = 3;

  // The combiner inputs are decoded once per register value into offsets of
  // [_regs]. A constant input points at the zero / 255 rows. The alpha
  // selectors of the C input read the alpha lane whatever the colour channel
  // is, which is a step of 0.
  // A register is two vectors: red and green, then blue and alpha.
  static const _regCombined = 0,
      _regTexture = 2,
      _regPrimitive = 4,
      _regShade = 6,
      _regEnvironment = 8,
      _regZero = 10,
      _regFull = 12;
  final _regs = Float64x2List(14)
    ..[_regFull] = Float64x2.splat(255)
    ..[_regFull + 1] = Float64x2.splat(255);
  // Per cycle: rgb A, B, C, D offsets, C step, and alpha A, B, C, D offsets.
  final _plan = Int32List(2 * 9);
  int _planKey0 = -1, _planKey1 = -1, _planCycles = 0;

  static const _rgbSource = [
    _regCombined, _regTexture, _regTexture, _regPrimitive, //
    _regShade, _regEnvironment
  ];

  static int _rgbOffset(int selector, int slot) {
    if (selector < 6) return _rgbSource[selector];
    if (selector == 6 && (slot == _rgbInputA || slot == _rgbInputD)) {
      return _regFull;
    }
    return _regZero;
  }

  static int _alphaOffset(int selector) => switch (selector) {
        0 => _regCombined + 1,
        1 || 2 => _regTexture + 1,
        3 => _regPrimitive + 1,
        4 => _regShade + 1,
        5 => _regEnvironment + 1,
        6 => _regFull + 1,
        _ => _regZero + 1
      };

  void _decodeCombiner(int cycles) {
    for (var cycle = 0; cycle < cycles; cycle++) {
      final a = cycle == 0 ? combine0.shr20.mask4 : combine0.shr5.mask4;
      final b = cycle == 0 ? combine1.shr28.mask4 : combine1.shr24.mask4;
      final cc = cycle == 0 ? combine0.shr15.mask5 : combine0.mask5;
      final d = cycle == 0 ? combine1.shr15.mask3 : combine1.shr6.mask3;
      final base = cycle * 9;
      _plan[base] = _rgbOffset(a, _rgbInputA);
      _plan[base + 1] = _rgbOffset(b, _rgbInputB);
      _plan[base + 3] = _rgbOffset(d, _rgbInputD);
      if (cc >= 7) {
        _plan[base + 4] = 0;
        _plan[base + 2] = switch (cc) {
          7 => _regCombined + 1,
          8 || 9 => _regTexture + 1,
          10 => _regPrimitive + 1,
          11 => _regShade + 1,
          12 => _regEnvironment + 1,
          _ => _regZero + 1
        };
      } else {
        _plan[base + 4] = 1;
        _plan[base + 2] = _rgbOffset(cc, _rgbInputC);
      }
      _plan[base + 5] = _alphaOffset(
          cycle == 0 ? combine0.shr12.mask3 : combine1.shr21.mask3);
      _plan[base + 6] =
          _alphaOffset(cycle == 0 ? combine1.shr12.mask3 : combine1.shr3.mask3);
      _plan[base + 7] =
          _alphaOffset(cycle == 0 ? combine0.shr9.mask3 : combine1.shr18.mask3);
      _plan[base + 8] =
          _alphaOffset(cycle == 0 ? combine1.shr9.mask3 : combine1.mask3);
    }
    _planKey0 = combine0;
    _planKey1 = combine1;
    _planCycles = cycles;
  }

  /// Runs the colour combiner. The result is the shared [_out], which the next
  /// call overwrites.
  Rgba _combine(Rgba shade, Rgba texture) {
    final out = _out;
    final mode = otherHigh.shr20.mask2;
    if (mode == 2) {
      out
        ..rg = texture.rg
        ..ba = texture.ba;
      return out;
    }
    final cycles = mode == 1 ? 2 : 1;
    if (_planKey0 != combine0 ||
        _planKey1 != combine1 ||
        _planCycles < cycles) {
      _decodeCombiner(cycles);
    }
    final regs = _regs, plan = _plan;
    final zero = Float64x2.zero(),
        full = Float64x2.splat(255),
        inv255 = Float64x2.splat(_inv255);
    regs[_regCombined] = zero;
    regs[_regCombined + 1] = zero;
    regs[_regPrimitive] = primitive.rg;
    regs[_regPrimitive + 1] = primitive.ba;
    regs[_regEnvironment] = environment.rg;
    regs[_regEnvironment + 1] = environment.ba;
    regs[_regTexture] = texture.rg;
    regs[_regTexture + 1] = texture.ba;
    regs[_regShade] = shade.rg;
    regs[_regShade + 1] = shade.ba;
    var rg = zero, ba = zero;
    for (var cycle = 0; cycle < cycles; cycle++) {
      final base = cycle * 9;
      final oa = plan[base],
          ob = plan[base + 1],
          oc = plan[base + 2],
          od = plan[base + 3];
      final Float64x2 c;
      final double cb;
      if (plan[base + 4] != 0) {
        c = regs[oc];
        cb = regs[oc + 1].x;
      } else {
        cb = regs[oc].y;
        c = Float64x2.splat(cb);
      }
      rg = ((regs[oa] - regs[ob]) * c * inv255 + regs[od]).max(zero).min(full);
      final a1 = Float64x2(regs[oa + 1].x, regs[plan[base + 5]].y),
          b1 = Float64x2(regs[ob + 1].x, regs[plan[base + 6]].y),
          c1 = Float64x2(cb, regs[plan[base + 7]].y),
          d1 = Float64x2(regs[od + 1].x, regs[plan[base + 8]].y);
      ba = ((a1 - b1) * c1 * inv255 + d1).max(zero).min(full);
      regs[_regCombined] = rg;
      regs[_regCombined + 1] = ba;
    }
    out
      ..rg = rg
      ..ba = ba;
    return out;
  }

  // Same as v.round().clamp(0, 255) for finite v, without the round() stub call.
  @pragma('vm:prefer-inline')
  static int _toByte(double v) =>
      v < 0 ? 0 : (v >= 255 ? 255 : (v + 0.5).toInt());

  @visibleForTesting
  bool pixel(int x, int y, Rgba color) => _put(x, y, color);

  bool _put(int x, int y, Rgba color) {
    if (x < scLeft ||
        x >= scRight ||
        x < 0 ||
        x >= width ||
        y < scTop ||
        y >= scBottom ||
        y < 0 ||
        y >= 576) {
      return false;
    }
    final r = color.r, g = color.g, b = color.b, a = color.a;
    if (a < 1) return false;
    final size = colorSize == 3 ? 4 : 2,
        at = colorImage + (y * width + x) * size;
    if (at + size > bus.ram.length) return false;
    var redValue = r, greenValue = g, blueValue = b;
    if (otherLow.bit14 && a < 255) {
      final old = u(at, size), alpha = a * _inv255, inverse = 1 - alpha;
      final oldRed =
              size == 4 ? _byte[old.shr24.mask8] : _fiveBit[old.shr11.mask5],
          oldGreen =
              size == 4 ? _byte[old.shr16.mask8] : _fiveBit[old.shr6.mask5],
          oldBlue =
              size == 4 ? _byte[old.shr8.mask8] : _fiveBit[old.shr1.mask5];
      redValue = redValue * alpha + oldRed * inverse;
      greenValue = greenValue * alpha + oldGreen * inverse;
      blueValue = blueValue * alpha + oldBlue * inverse;
    }
    bus.ramWrite(at, _pack(redValue, greenValue, blueValue, size), size);
    return true;
  }

  static int _pack(
      double redValue, double greenValue, double blueValue, int size) {
    final red = _toByte(redValue),
        green = _toByte(greenValue),
        blue = _toByte(blueValue);
    return size == 4
        ? red.shl24 | green.shl16 | blue.shl8 | 255
        : red.shr3.shl11 | green.shr3.shl6 | blue.shr3.shl1 | 1;
  }

  void textureRect(int w0, int w1, int st, int delta, bool flip) {
    if (!rasterize) return;
    final left = w1.shr12.mask12 / 4, top = w1.mask12 / 4;
    var right = w0.shr12.mask12 / 4, bottom = w0.mask12 / 4;
    final tile = w1.shr24.mask3, cycle = otherHigh.shr20.mask2;
    if (cycle >= 2) {
      right++;
      bottom++;
    }
    final s = st.shr16.rel16 / 32, t = st.rel16 / 32;
    final ds = delta.shr16.rel16 / 1024 / (cycle == 2 ? 4 : 1),
        dt = delta.rel16 / 1024;
    for (var y = math.max(scTop, top.ceil());
        y < math.min(scBottom, bottom.ceil());
        y++) {
      for (var x = math.max(scLeft, left.ceil());
          x < math.min(scRight, right.ceil());
          x++) {
        _texel(
            tile,
            Float64x2(s + (flip ? y - top : x - left) * ds,
                t + (flip ? x - left : y - top) * dt));
        _put(x, y, _combine(_whiteColor, _tex));
      }
    }
  }

  void rdp(int w0, int w1) {
    final op = w0.shr24;
    switch (op) {
      case 0xff:
        colorImage = resolve(w1);
        colorSize = w0.shr19.mask2;
        width = w0.mask12 + 1;
      case 0xfe:
        zImage = resolve(w1);
      case 0xfd:
        textureImage = resolve(w1);
        textureSize = w0.shr19.mask2;
        textureWidth = w0.mask12 + 1;
        textureFormat = w0.shr21.mask3;
      case 0xfc:
        combine0 = w0.mask24;
        combine1 = w1;
      case 0xfa:
        primitive.copy(Rgba.fromWord(w1));
      case 0xfb:
        environment.copy(Rgba.fromWord(w1));
      case 0xf8:
        fog.copy(Rgba.fromWord(w1));
      case 0xf7:
        fillColor = w1;
      case 0xf6:
        if (!rasterize) break;
        final x0 = w1.shr12.mask12,
            y0 = w1.mask12,
            x1 = w0.shr12.mask12,
            y1 = w0.mask12;
        if (colorImage == zImage) {
          depth.fillRange(0, depth.length, double.infinity);
          break;
        }
        final xStart = math.max(scLeft, x0 ~/ 4),
            xEnd = math.min(math.min(scRight, width) - 1, x1 ~/ 4);
        if (otherHigh.shr20.mask2 == 3) {
          final size = colorSize == 3 ? 4 : 2, ramData = bus.ramData;
          final ramLength = bus.ram.length;
          for (var y = math.max(scTop, y0 ~/ 4);
              y <= math.min(scBottom - 1, y1 ~/ 4);
              y++) {
            for (var x = xStart; x <= xEnd; x++) {
              final at = colorImage + (y * width + x) * size;
              if (at + size > ramLength) continue;
              if (size == 4) {
                ramData.setUint32(at & 0x7fffff, fillColor);
              } else {
                ramData.setUint16(at & 0x7fffff,
                    x.isEven ? fillColor.shr16 : fillColor.mask16);
              }
            }
          }
        } else {
          // The inputs are constant, so the combined colour is the same for
          // every pixel of the rectangle.
          final color = _combine(_whiteColor, _whiteColor);
          for (var y = math.max(scTop, y0 ~/ 4);
              y <= math.min(scBottom - 1, y1 ~/ 4);
              y++) {
            for (var x = xStart; x <= xEnd; x++) {
              _put(x, y, color);
            }
          }
        }
      case 0xf5:
        final tile = tiles[w1.shr24.mask3];
        tile.format = w0.shr21.mask3;
        tile.size = w0.shr19.mask2;
        tile.line = w0.shr9.mask9;
        tile.tmem = w0.mask9;
        tile.palette = w1.shr20.mask4;
        tile.tMode = w1.shr18.mask2;
        tile.tMask = w1.shr14.mask4;
        tile.tShift = w1.shr10.mask4;
        tile.sMode = w1.shr8.mask2;
        tile.sMask = w1.shr4.mask4;
        tile.sShift = w1.mask4;
      case 0xf2:
        final tile = tiles[w1.shr24.mask3];
        tile.left = w0.shr12.mask12 / 4;
        tile.top = w0.mask12 / 4;
        tile.right = w1.shr12.mask12 / 4;
        tile.bottom = w1.mask12 / 4;
      case 0xf3:
        final tile = tiles[w1.shr24.mask3], count = w1.shr12.mask12 + 1;
        final bytes = (count * (4 << textureSize) + 7) ~/ 8;
        final start = textureImage +
            ((w0.mask12 ~/ 4 * textureWidth + w0.shr12.mask12 ~/ 4) *
                    (4 << textureSize)) ~/
                8;
        for (var i = 0; i < bytes; i++) {
          tmem[(tile.tmem * 8 + i).mask12] = u(start + i, 1);
        }
      case 0xf4:
        final tile = tiles[w1.shr24.mask3],
            x0 = w0.shr12.mask12 ~/ 4,
            y0 = w0.mask12 ~/ 4,
            x1 = w1.shr12.mask12 ~/ 4,
            y1 = w1.mask12 ~/ 4;
        final bytes = ((x1 - x0 + 1) * (4 << textureSize) + 7) ~/ 8;
        for (var y = y0; y <= y1; y++) {
          for (var i = 0; i < bytes; i++) {
            tmem[(tile.tmem * 8 + (y - y0) * tile.line * 8 + i).mask12] = u(
                textureImage +
                    ((y * textureWidth + x0) * (4 << textureSize)) ~/ 8 +
                    i,
                1);
          }
        }
      case 0xf0:
        final tile = tiles[w1.shr24.mask3], count = w1.shr14.mask10 + 1;
        for (var i = 0; i < count; i++) {
          for (var j = 0; j < 8; j++) {
            tmem[(tile.tmem * 8 + i * 8 + j).mask12] =
                u(textureImage + i * 2 + j.mask1, 1);
          }
        }
      case 0xed:
        scLeft = w0.shr12.mask12 ~/ 4;
        scTop = w0.mask12 ~/ 4;
        scRight = w1.shr12.mask12 ~/ 4;
        scBottom = w1.mask12 ~/ 4;
      case 0xef:
        otherHigh = w0.mask24;
        otherLow = w1;
      case 0xe9:
        bus.interrupt(32);
      case 0xe6:
      case 0xe7:
      case 0xe8:
      case 0xee:
      case 0xec:
      case 0xeb:
      case 0xea:
      case 0xf9:
        break;
      default:
        throw UnsupportedError('RDP opcode 0x${op.hex}');
    }
  }

  void commands(int start, int end) {
    if (bus.dp[3].bit0) throw UnsupportedError('RDP XBUS command source');
    for (var at = start; at < end; at += 8) {
      rdp(u(at, 4) | 0xc0000000, u(at + 4, 4));
    }
  }
}
