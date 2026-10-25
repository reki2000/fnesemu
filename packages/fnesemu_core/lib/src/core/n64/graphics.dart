import 'dart:math' as math;
import 'dart:typed_data';

import '../../state.dart';
import '../../util/int.dart';

import 'bus.dart';

class N64Tile {
  int format = 0, size = 0, line = 0, tmem = 0, palette = 0;
  int sMode = 0, tMode = 0, sMask = 0, tMask = 0, sShift = 0, tShift = 0;
  double left = 0, top = 0, right = 0, bottom = 0;
}

class N64Vertex {
  final List<double> clip, color;
  final double s, t;
  const N64Vertex(this.clip, this.color, this.s, this.t);
  N64Vertex mix(N64Vertex b, double f) => N64Vertex(
      List.generate(4, (i) => clip[i] + (b.clip[i] - clip[i]) * f),
      List.generate(4, (i) => color[i] + (b.color[i] - color[i]) * f),
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
  final _textureColor = Float64List(4), _combined = Float64List(4);
  final _shade = Float64List(4);
  static const _white = <double>[255, 255, 255, 255];
  static final _fiveBit = List<double>.generate(32, (v) => v * 255 / 31);
  // Pixel scratch buffers are consumed synchronously, never retained by vertices.
  List<double> _textureRgba(
      double red, double green, double blue, double alpha) {
    _textureColor[0] = red;
    _textureColor[1] = green;
    _textureColor[2] = blue;
    _textureColor[3] = alpha;
    return _textureColor;
  }

  List<double> _texture16(int value) => _textureRgba(
      _fiveBit[value.shr11.mask5],
      _fiveBit[value.shr6.mask5],
      _fiveBit[value.shr1.mask5],
      value.mask1 * 255.0);

  final lights = List.generate(8, (_) => List<double>.filled(6, 0));
  List<double> model = identity(), projection = identity();
  final stack = <List<double>>[];
  List<double> scale = [160, 120, 511], translate = [160, 120, 511];
  int geometry = 0, numLights = 1;
  int colorImage = 0, colorSize = 2, width = 320, zImage = 0;
  int textureImage = 0, textureSize = 2, textureWidth = 1, textureFormat = 0;
  int activeTile = 0;
  double textureS = 1, textureT = 1;
  bool textureOn = false;
  int otherHigh = 0, otherLow = 0, combine0 = 0, combine1 = 0, fillColor = 0;
  List<double> primitive = [255, 255, 255, 255],
      environment = [255, 255, 255, 255],
      fog = [0, 0, 0, 0];
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
      w.floats(v.clip);
      w.floats(v.color);
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
    lights.forEach(w.floats);
    w.floats(model);
    w.floats(projection);
    w.int32(stack.length);
    stack.forEach(w.floats);
    for (final v in [scale, translate, primitive, environment, fog]) {
      w.floats(v);
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
          ? N64Vertex(s.floats(), s.floats(), s.float64(), s.float64())
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
      light.setAll(0, s.floats());
    }
    model = s.floats();
    projection = s.floats();
    stack
      ..clear()
      ..addAll([for (var n = s.int32(); n > 0; n--) s.floats()]);
    scale = s.floats();
    translate = s.floats();
    primitive = s.floats();
    environment = s.floats();
    fog = s.floats();
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

  static List<double> identity() =>
      [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
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
      light.fillRange(0, light.length, 0);
    }
    scale = [160, 120, 511];
    translate = [160, 120, 511];
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
    primitive = [255, 255, 255, 255];
    environment = [255, 255, 255, 255];
    fog = [0, 0, 0, 0];
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
  List<double> matrix(int addr) => List.generate(
      16, (i) => signed(addr + i * 2, 2) + u(addr + 32 + i * 2, 2) / 65536);
  List<double> multiply(List<double> a, List<double> b) =>
      List.generate(16, (i) {
        final row = i ~/ 4, col = i % 4;
        return List.generate(4, (k) => a[row * 4 + k] * b[k * 4 + col])
            .reduce((x, y) => x + y);
      });
  List<double> transform(List<double> v, List<double> m) => List.generate(
      4,
      (i) =>
          List.generate(4, (k) => v[k] * m[k * 4 + i]).reduce((a, b) => a + b));
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
                stack.add(List.of(model));
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
              scale = List.generate(3, (i) => signed(addr + i * 2, 2) / 4);
              translate =
                  List.generate(3, (i) => signed(addr + 8 + i * 2, 2) / 4);
            } else if (index == 10) {
              final l = lights[(offset ~/ 24 - 2).clamp(0, 7)];
              for (var i = 0; i < 3; i++) {
                l[i] = u(addr + i, 1).toDouble();
                l[i + 3] = signed(addr + 8 + i, 1) / 127;
              }
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
              stack.add(List.of(model));
            }
            model = flags.bit1 ? m : multiply(m, model);
          }
        case 3:
          final index = w0.shr16.mask8, addr = resolve(w1);
          if (index == 0x80) {
            scale = List.generate(3, (i) => signed(addr + i * 2, 2) / 4);
            translate =
                List.generate(3, (i) => signed(addr + 8 + i * 2, 2) / 4);
          } else if (index >= 0x86 && index <= 0x94) {
            final l = lights[(index - 0x86) ~/ 2];
            for (var i = 0; i < 3; i++) {
              l[i] = u(addr + i, 1).toDouble();
              l[i + 3] = signed(addr + 8 + i, 1) / 127;
            }
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
            for (var i = 0; i < 3; i++) {
              l[i] = w1.shr((3 - i) * 8).mask8.toDouble();
            }
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
            vertices[index] = N64Vertex(v.clip, rgba(w1), v.s, v.t);
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
    for (var y = math.max(scTop, math.max(0, y0.ceil()));
        y < math.min(scBottom, y0 + frameHeight);
        y++) {
      final sy = (imageY + (y - y0) * scaleY).floor() % imageHeight;
      for (var x = math.max(scLeft, math.max(0, x0.ceil()));
          x < math.min(math.min(scRight, width), x0 + frameWidth);
          x++) {
        final dx = flip ? frameWidth - 1 - (x - x0) : x - x0;
        final sx = (imageX + dx * scaleX).floor() % imageWidth;
        final value = u(source + (sy * imageWidth + sx) * bytes, bytes);
        final color = size == 2 ? _texture16(value) : rgba(value);
        pixel(x, y, _combine(_white, color));
      }
    }
  }

  void _loadVertices(int addr, int first, int count) {
    final combined = multiply(model, projection);
    if (first + count > vertices.length) {
      throw StateError('RSP vertex buffer overflow');
    }
    for (var i = 0; i < count; i++) {
      final p = addr + i * 16;
      final clip = transform(
          [signed(p, 2), signed(p + 2, 2), signed(p + 4, 2), 1], combined);
      final color = List.generate(4, (c) => u(p + 12 + c, 1).toDouble());
      if (geometry.bit17) {
        final normal = [
          signed(p + 12, 1) / 127,
          signed(p + 13, 1) / 127,
          signed(p + 14, 1) / 127
        ];
        final n = List.generate(
            3,
            (c) =>
                normal[0] * model[c] +
                normal[1] * model[4 + c] +
                normal[2] * model[8 + c]);
        final length = math.sqrt(n.fold(0.0, (v, x) => v + x * x));
        if (length > 0) {
          for (var c = 0; c < 3; c++) {
            n[c] /= length;
          }
        }
        final ambient = lights[numLights.clamp(0, 7)];
        for (var c = 0; c < 3; c++) {
          color[c] = ambient[c];
        }
        for (var l = 0; l < numLights.clamp(0, 7); l++) {
          final light = lights[l];
          final dot = math.max(
              0.0, n[0] * light[3] + n[1] * light[4] + n[2] * light[5]);
          for (var c = 0; c < 3; c++) {
            color[c] += light[c] * dot;
          }
        }
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
      double distance(N64Vertex v) =>
          v.clip[3] + (plane.isEven ? v.clip[plane ~/ 2] : -v.clip[plane ~/ 2]);
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
  void triangle(N64Vertex a, N64Vertex b, N64Vertex c) {
    if (!rasterize) return;
    if ([a, b, c].any((v) => v.clip[3].abs() < 1e-9)) return;
    final vs = [a, b, c];
    final x =
        vs.map((v) => v.clip[0] / v.clip[3] * scale[0] + translate[0]).toList();
    final y = vs
        .map((v) => -v.clip[1] / v.clip[3] * scale[1] + translate[1])
        .toList();
    final z =
        vs.map((v) => v.clip[2] / v.clip[3] * scale[2] + translate[2]).toList();
    double edge(
            double ax, double ay, double bx, double by, double px, double py) =>
        (px - ax) * (by - ay) - (py - ay) * (bx - ax);
    final area = edge(x[0], y[0], x[1], y[1], x[2], y[2]);
    if (area.abs() < 1e-8) return;
    if ((geometry.bit13 && area < 0) || (geometry.bit12 && area > 0)) {
      return;
    }
    triangles++;
    final minX = math.max(scLeft, x.reduce(math.min).floor()),
        maxX =
            math.min(math.min(scRight, width) - 1, x.reduce(math.max).ceil());
    final minY = math.max(scTop, y.reduce(math.min).floor()),
        maxY = math.min(math.min(scBottom, 576) - 1, y.reduce(math.max).ceil());
    final inverse = vs.map((v) => 1 / v.clip[3]).toList();
    final depthBuffer = depth;
    final waStep = (y[2] - y[1]) / area,
        wbStep = (y[0] - y[2]) / area,
        wcStep = -waStep - wbStep;
    double delta(double va, double vb, double vc) =>
        waStep * va + wbStep * vb + wcStep * vc;
    final zStep = delta(z[0], z[1], z[2]);
    final redStep = delta(a.color[0], b.color[0], c.color[0]),
        greenStep = delta(a.color[1], b.color[1], c.color[1]),
        blueStep = delta(a.color[2], b.color[2], c.color[2]),
        alphaStep = delta(a.color[3], b.color[3], c.color[3]);
    final sa = a.s * inverse[0],
        sb = b.s * inverse[1],
        sc = c.s * inverse[2],
        ta = a.t * inverse[0],
        tb = b.t * inverse[1],
        tc = c.t * inverse[2];
    final sStep = delta(sa, sb, sc),
        tStep = delta(ta, tb, tc),
        inverseStep = delta(inverse[0], inverse[1], inverse[2]);
    final depthTest = geometry.bit0 && otherLow.bit4,
        depthWrite = geometry.bit0 && otherLow.bit5;
    for (var py = minY; py <= maxY; py++) {
      // Narrow the row to the pixels that can be covered (a weight w + step * k
      // must reach zero within the edge tolerance), with a margin of one pixel;
      // the per-pixel coverage test below stays authoritative.
      final wa0 = edge(x[1], y[1], x[2], y[2], minX + 0.5, py + 0.5) / area,
          wb0 = edge(x[2], y[2], x[0], y[0], minX + 0.5, py + 0.5) / area;
      var first = 0, last = maxX - minX;
      for (final (w, step) in [
        (wa0, waStep),
        (wb0, wbStep),
        (1 - wa0 - wb0, wcStep)
      ]) {
        if (step > 0) {
          first = math.max(first, ((-1e-9 - w) / step).floor() - 1);
        } else if (step < 0) {
          last = math.min(last, ((w + 1e-9) / -step).ceil() + 1);
        } else if (w < -1e-9) {
          last = -1;
        }
      }
      if (first > last) continue;
      final startX = minX + first, endX = minX + last;
      var wa = first == 0
              ? wa0
              : edge(x[1], y[1], x[2], y[2], startX + 0.5, py + 0.5) / area,
          wb = first == 0
              ? wb0
              : edge(x[2], y[2], x[0], y[0], startX + 0.5, py + 0.5) / area;
      final wc = 1 - wa - wb;
      var dz = wa * z[0] + wb * z[1] + wc * z[2],
          red = wa * a.color[0] + wb * b.color[0] + wc * c.color[0],
          green = wa * a.color[1] + wb * b.color[1] + wc * c.color[1],
          blue = wa * a.color[2] + wb * b.color[2] + wc * c.color[2],
          alpha = wa * a.color[3] + wb * b.color[3] + wc * c.color[3],
          ss = wa * sa + wb * sb + wc * sc,
          tt = wa * ta + wb * tb + wc * tc,
          divisor = wa * inverse[0] + wb * inverse[1] + wc * inverse[2];
      for (var px = startX;
          px <= endX;
          px++,
          wa += waStep,
          wb += wbStep,
          dz += zStep,
          red += redStep,
          green += greenStep,
          blue += blueStep,
          alpha += alphaStep,
          ss += sStep,
          tt += tStep,
          divisor += inverseStep) {
        // Re-evaluate coverage near an edge: accumulated roundoff must not
        // introduce cracks in adjacent triangles sharing that edge.
        var inside = wa >= 0 && wb >= 0 && 1 - wa - wb >= 0;
        if (wa.abs() < 1e-10 ||
            wb.abs() < 1e-10 ||
            (1 - wa - wb).abs() < 1e-10) {
          final exactA =
                  edge(x[1], y[1], x[2], y[2], px + 0.5, py + 0.5) / area,
              exactB = edge(x[2], y[2], x[0], y[0], px + 0.5, py + 0.5) / area;
          inside = exactA >= 0 && exactB >= 0 && 1 - exactA - exactB >= 0;
        }
        if (!inside) continue;
        final at = py * width + px;
        if (depthTest && dz > depthBuffer[at]) {
          continue;
        }
        _shade[0] = red;
        _shade[1] = green;
        _shade[2] = blue;
        _shade[3] = alpha;
        final written = pixel(
            px,
            py,
            _combine(
                _shade,
                textureOn
                    ? _texel(activeTile, ss / divisor, tt / divisor)
                    : _white));
        // Rejected transparent texels must not occlude later geometry.
        if (written && depthWrite) depthBuffer[at] = dz;
      }
    }
  }

  List<double> rgba(int v) =>
      List.generate(4, (i) => v.shr((3 - i) * 8).mask8.toDouble());
  List<double> rgba16(int v) => [
        v.shr11.mask5 * 255 / 31,
        v.shr6.mask5 * 255 / 31,
        v.shr1.mask5 * 255 / 31,
        v.mask1 * 255.0
      ];

  /// Public inspection returns a snapshot; the rasterizer uses private scratch.
  List<double> texel(int index, double s, double t) =>
      List<double>.of(_texel(index, s, t));
  List<double> combine(List<double> shade, List<double> texture) =>
      List<double>.of(_combine(shade, texture));

  static int _coordinate(
      double value, double low, double high, int shift, int mode, int mask) {
    if (shift != 0) {
      value = shift <= 10 ? value / (1 << shift) : value * (1 << (16 - shift));
    }
    var coord = (value - low).floor(), extent = (high - low).floor();
    if (mode.bit1) coord = coord.clamp(0, math.max(0, extent));
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

  List<double> _texel(int index, double s, double t) {
    final tile = tiles[index];
    final x = _coordinate(
            s, tile.left, tile.right, tile.sShift, tile.sMode, tile.sMask),
        y = _coordinate(
            t, tile.top, tile.bottom, tile.tShift, tile.tMode, tile.tMask);
    final row = tile.line * 8;
    final offset = (tile.tmem * 8 + y * row + x * (4 << tile.size) ~/ 8).mask12;
    var v = tmem[offset];
    if (tile.size == 0) v = (x.isEven ? v.shr4 : v).mask4;
    if (tile.size >= 2) v = v.shl8 | tmem[(offset + 1).mask12];
    if (tile.size == 3) {
      v = v.shl16 | tmem[(offset + 2).mask12].shl8 | tmem[(offset + 3).mask12];
    }
    if (tile.format == 0) {
      return tile.size == 3
          ? _textureRgba(v.shr24.mask8.toDouble(), v.shr16.mask8.toDouble(),
              v.shr8.mask8.toDouble(), v.mask8.toDouble())
          : _texture16(v);
    }
    if (tile.format == 2) {
      final paletteIndex = tile.size == 0 ? tile.palette * 16 + v : v;
      final p = (2048 + paletteIndex * 8).mask12;
      return _texture16(tmem[p].shl8 | tmem[p + 1]);
    }
    if (tile.format == 3) {
      if (tile.size == 2) {
        final intensity = v.shr8.toDouble();
        return _textureRgba(
            intensity, intensity, intensity, v.mask8.toDouble());
      }
      final intensity = tile.size == 1 ? v.shr4 * 17 : v.shr1.mask3 * 255 / 7,
          alpha = tile.size == 1 ? v.mask4 * 17 : v.mask1 * 255;
      return _textureRgba(intensity.toDouble(), intensity.toDouble(),
          intensity.toDouble(), alpha.toDouble());
    }
    final intensity = tile.size == 0 ? v * 17 : v;
    return _textureRgba(intensity.toDouble(), intensity.toDouble(),
        intensity.toDouble(), intensity.toDouble());
  }

  // RGB equation: (A - B) * C / 255 + D. C has additional alpha selectors.
  static const _rgbInputA = 0, _rgbInputB = 1, _rgbInputC = 2, _rgbInputD = 3;

  // The combiner inputs are decoded once per register value into offsets of
  // [_regs]. A constant input points at the zero / 255 rows. The alpha
  // selectors of the C input read channel 3 whatever the colour channel is,
  // which is a step of 0.
  static const _regCombined = 0,
      _regTexture = 4,
      _regPrimitive = 8,
      _regShade = 12,
      _regEnvironment = 16,
      _regZero = 20,
      _regFull = 24;
  final _regs = Float64List(28)..fillRange(24, 28, 255);
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
        0 => _regCombined + 3,
        1 || 2 => _regTexture + 3,
        3 => _regPrimitive + 3,
        4 => _regShade + 3,
        5 => _regEnvironment + 3,
        6 => _regFull,
        _ => _regZero
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
          7 => _regCombined + 3,
          8 || 9 => _regTexture + 3,
          10 => _regPrimitive + 3,
          11 => _regShade + 3,
          12 => _regEnvironment + 3,
          _ => _regZero
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

  List<double> _combine(List<double> shade, List<double> texture) {
    final mode = otherHigh.shr20.mask2;
    if (mode == 2) return texture;
    final cycles = mode == 1 ? 2 : 1;
    if (_planKey0 != combine0 ||
        _planKey1 != combine1 ||
        _planCycles < cycles) {
      _decodeCombiner(cycles);
    }
    final regs = _regs, plan = _plan, combined = _combined;
    for (var i = 0; i < 4; i++) {
      combined[i] = 0;
      regs[_regCombined + i] = 0;
      regs[_regTexture + i] = texture[i];
      regs[_regPrimitive + i] = primitive[i];
      regs[_regShade + i] = shade[i];
      regs[_regEnvironment + i] = environment[i];
    }
    for (var cycle = 0; cycle < cycles; cycle++) {
      final base = cycle * 9;
      final oa = plan[base],
          ob = plan[base + 1],
          oc = plan[base + 2],
          od = plan[base + 3],
          stepC = plan[base + 4];
      for (var i = 0; i < 3; i++) {
        final v = (regs[oa + i] - regs[ob + i]) * regs[oc + i * stepC] / 255 +
            regs[od + i];
        combined[i] = v < 0 ? 0 : (v > 255 ? 255 : v);
      }
      final v = (regs[plan[base + 5]] - regs[plan[base + 6]]) *
              regs[plan[base + 7]] /
              255 +
          regs[plan[base + 8]];
      combined[3] = v < 0 ? 0 : (v > 255 ? 255 : v);
      // The next cycle reads this cycle's result.
      for (var i = 0; i < 4; i++) {
        regs[_regCombined + i] = combined[i];
      }
    }
    return combined;
  }

  static int _byte(double v) {
    final r = v.round();
    return r < 0 ? 0 : (r > 255 ? 255 : r);
  }

  bool pixel(int x, int y, List<double> color) {
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
    if (color[3] < 1) return false;
    final size = colorSize == 3 ? 4 : 2,
        at = colorImage + (y * width + x) * size;
    if (at + size > bus.ram.length) return false;
    var redValue = color[0], greenValue = color[1], blueValue = color[2];
    if (otherLow.bit14 && color[3] < 255) {
      final old = u(at, size), alpha = color[3] / 255, inverse = 1 - alpha;
      final oldRed = size == 4
              ? old.shr24.mask8.toDouble()
              : _fiveBit[old.shr11.mask5],
          oldGreen =
              size == 4 ? old.shr16.mask8.toDouble() : _fiveBit[old.shr6.mask5],
          oldBlue =
              size == 4 ? old.shr8.mask8.toDouble() : _fiveBit[old.shr1.mask5];
      redValue = redValue * alpha + oldRed * inverse;
      greenValue = greenValue * alpha + oldGreen * inverse;
      blueValue = blueValue * alpha + oldBlue * inverse;
    }
    final red = _byte(redValue),
        green = _byte(greenValue),
        blue = _byte(blueValue);
    bus.ramWrite(
        at,
        size == 4
            ? red.shl24 | green.shl16 | blue.shl8 | 255
            : red.shr3.shl11 | green.shr3.shl6 | blue.shr3.shl1 | 1,
        size);
    return true;
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
        final tex = _texel(tile, s + (flip ? y - top : x - left) * ds,
            t + (flip ? x - left : y - top) * dt);
        pixel(x, y, _combine(_white, tex));
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
        primitive = rgba(w1);
      case 0xfb:
        environment = rgba(w1);
      case 0xf8:
        fog = rgba(w1);
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
        for (var y = math.max(scTop, y0 ~/ 4);
            y <= math.min(scBottom - 1, y1 ~/ 4);
            y++) {
          for (var x = math.max(scLeft, x0 ~/ 4);
              x <= math.min(math.min(scRight, width) - 1, x1 ~/ 4);
              x++) {
            if (otherHigh.shr20.mask2 == 3) {
              final size = colorSize == 3 ? 4 : 2,
                  at = colorImage + (y * width + x) * size;
              if (at + size <= bus.ram.length) {
                bus.ramWrite(
                    at,
                    size == 4
                        ? fillColor
                        : (x.isEven ? fillColor.shr16 : fillColor.mask16),
                    size);
              }
            } else {
              pixel(x, y, _combine(_white, _white));
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
