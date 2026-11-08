part of 'gpu_render.dart';

/// A triangle of a [RenderFrame] before batching.
class _FrameTriangle {
  _FrameTriangle(this.order, this.a, this.b, this.c, this.texture, this.state,
      {this.background = false});
  final int order, texture, state;
  final _Vertex a, b, c;

  /// A triangle of the background plane, which does not count for the
  /// depth range of the frame.
  final bool background;
  double get depth => (a.z + b.z + c.z) / 3;
}

/// Builds the [RenderFrame] of a render from the region array and the
/// object lists, for a host GPU. Every object is taken once, however many
/// tiles list it, and is clipped to the rectangle of those tiles, which
/// keeps the user tile clip of the tile accelerator. This is a functional
/// approximation: modifier volumes, the secondary accumulation buffer, bump
/// maps, MIP levels and the color clamp are left out, and auto-sorted
/// translucent triangles are ordered by their mean depth.
extension _FrameBuilder on DcGpuRender {
  RenderFrame _buildFrame() {
    final type2 = read(0x7c) & 0x200000 != 0;
    // The object lists of each pass with the tiles that list them, as in
    // [_FrameBuilder._tiles].
    final lists = [<int, int>{}, <int, int>{}, <int, int>{}];
    var presort = false, first = true, tilesX = 0, tilesY = 0;
    for (var region = read(0x2c);; region += type2 ? 24 : 20) {
      final control = _word(region);
      final x = (control >> 2) & 63, y = (control >> 8) & 63;
      if (x >= tilesX) tilesX = x + 1;
      if (y >= tilesY) tilesY = y + 1;
      final tile = x | y << 8 | x << 16 | y << 24;
      if (first) {
        presort = type2 ? control & 0x20000000 != 0 : read(0x98) & 1 != 0;
        first = false;
      }
      final opaque = _word(region + 4), translucent = _word(region + 12);
      final punch = type2 ? _word(region + 20) : 0x80000000;
      for (final (pass, pointer) in [
        (0, opaque),
        (1, punch),
        (2, translucent)
      ]) {
        if (pointer & 0x80000000 == 0) {
          final list = pointer & 0xfffffc;
          lists[pass][list] = _tiles(lists[pass][list], tile);
        }
      }
      if (control & 0x80000000 != 0) break;
    }
    final textures = <int, int>{};
    final textureList = <RenderTexture>[];
    final triangles = [
      <_FrameTriangle>[],
      <_FrameTriangle>[],
      <_FrameTriangle>[]
    ];
    final width = math.min(tilesX * 32, ((read(0x68) >> 16) & 0x7ff) + 1);
    final height = math.min(tilesY * 32, ((read(0x6c) >> 16) & 0x3ff) + 1);
    _frameBackgroundPlane(width, height, textures, textureList, triangles[0]);
    for (var pass = 0; pass < 3; pass++) {
      // The parameters of each object with the union of its strip masks and
      // of its tiles.
      final objects = <int, (int, int, int)>{};
      for (final MapEntry(key: list, value: tiles) in lists[pass].entries) {
        _frameObjects(list, tiles, objects);
      }
      final addresses = objects.keys.toList()..sort();
      for (final parameter in addresses) {
        final (pointer, mask, tiles) = objects[parameter]!;
        _frameObject(parameter, pointer, mask, tiles, pass, textures,
            textureList, triangles[pass]);
      }
    }
    if (!presort) {
      // Farther triangles first, then in input order.
      triangles[2].sort((p, q) {
        final c = p.depth.compareTo(q.depth);
        return c != 0 ? c : p.order.compareTo(q.order);
      });
    }
    final count = triangles.fold(0, (n, list) => n + list.length);
    final vertices = Float32List(count * 3 * RenderFrame.vertexFloats);
    final batches = <RenderBatch>[];
    var index = 0, o = 0;
    var maximumDepth = _value(read(0x88));
    for (var pass = 0; pass < 3; pass++) {
      for (final t in triangles[pass]) {
        final last = batches.isEmpty ? null : batches.last;
        if (last != null &&
            last.pass == pass &&
            last.texture == t.texture &&
            last.state == t.state) {
          batches.last = RenderBatch(
              pass: pass,
              first: last.first,
              count: last.count + 1,
              texture: t.texture,
              state: t.state);
        } else {
          batches.add(RenderBatch(
              pass: pass,
              first: index,
              count: 1,
              texture: t.texture,
              state: t.state));
        }
        for (final v in [t.a, t.b, t.c]) {
          if (!t.background && v.z > maximumDepth) maximumDepth = v.z;
          vertices[o++] = v.x;
          vertices[o++] = v.y;
          vertices[o++] = v.z;
          vertices[o++] = v.u;
          vertices[o++] = v.v;
          for (final color in [v.color, v.offsetColor]) {
            vertices[o++] = ((color >> 16) & 255) / 255;
            vertices[o++] = ((color >> 8) & 255) / 255;
            vertices[o++] = (color & 255) / 255;
            vertices[o++] = ((color >> 24) & 255) / 255;
          }
        }
        index++;
      }
    }
    final (clearColor, clearDepth) = _frameBackground();
    return RenderFrame(
      // The tiles of the region array, inside the global tile clip.
      width: width,
      height: height,
      clearColor: clearColor,
      clearDepth: clearDepth,
      depthScale: maximumDepth > 0 ? 0.999 / maximumDepth : 1,
      vertices: vertices,
      batches: batches,
      textures: textureList,
      fogTable: fog.tableBytes,
      fogScale: fog.scale,
      fogColor: fog.tableColor,
      vertexFogColor: fog.vertexColor,
      alphaReference: read(0x11c) & 255,
      target: read(0x60),
    );
  }

  /// The union of two tile rectangles, each the first and the last tile as
  /// x | y << 8 | lastX << 16 | lastY << 24; [a] may be null for none.
  static int _tiles(int? a, int b) {
    if (a == null) return b;
    int lower(int shift) => math.min((a >> shift) & 255, (b >> shift) & 255);
    int upper(int shift) => math.max((a >> shift) & 255, (b >> shift) & 255);
    return lower(0) | lower(8) << 8 | upper(16) << 16 | upper(24) << 24;
  }

  void _frameObjects(int address, int tiles, Map<int, (int, int, int)> objects) {
    final links = <int>{};
    for (;; address += 4) {
      final pointer = _word(address);
      if (pointer >> 29 == 7) {
        if (pointer & 0x10000000 != 0 || !links.add(address)) return;
        address = (pointer & 0xfffffc) - 4;
        continue;
      }
      final kind = pointer & 0x80000000 == 0 ? 0 : pointer >> 29;
      var parameter = read(0x20) + ((pointer & 0x1fffff) * 4);
      if (kind == 0) {
        final mask = (pointer >> 25) & 63;
        final previous = objects[parameter];
        objects[parameter] = (
          pointer,
          (previous?.$2 ?? 0) | mask,
          _tiles(previous?.$3, tiles)
        );
        continue;
      }
      if (kind != 4 && kind != 5) continue;
      final count = ((pointer >> 25) & 15) + 1;
      for (var i = 0; i < count; i++) {
        objects[parameter] =
            (pointer, 0, _tiles(objects[parameter]?.$3, tiles));
        final isp = _word(parameter);
        final textured = isp & 0x02000000 != 0;
        final hasOffset = textured && isp & 0x01000000 != 0;
        final attributes = 1 +
            (textured
                ? (isp & 0x00400000 != 0 ? 1 : 2) + (hasOffset ? 1 : 0)
                : 0);
        final twoVolumes = pointer & 0x01000000 != 0 && read(0x74) & 0x100 == 0;
        final stride = 3 + attributes * (twoVolumes ? 2 : 1);
        final header = twoVolumes ? 5 : 3;
        parameter += (header + (kind == 4 ? 3 : 4) * stride) * 4;
      }
    }
  }

  void _frameObject(
      int parameter,
      int pointer,
      int mask,
      int tiles,
      int pass,
      Map<int, int> textures,
      List<RenderTexture> textureList,
      List<_FrameTriangle> out) {
    final kind = pointer & 0x80000000 == 0 ? 0 : pointer >> 29;
    final isp = _word(parameter);
    final textured = isp & 0x02000000 != 0;
    final hasOffset = textured && isp & 0x01000000 != 0;
    final attributes = 1 +
        (textured ? (isp & 0x00400000 != 0 ? 1 : 2) + (hasOffset ? 1 : 0) : 0);
    final twoVolumes = pointer & 0x01000000 != 0 && read(0x74) & 0x100 == 0;
    final stride = 3 + attributes * (twoVolumes ? 2 : 1);
    final header = twoVolumes ? 5 : 3;
    final tsp = _word(parameter + 4);
    final sourceSecondary = tsp & 0x02000000 != 0;
    final texture = textured && !sourceSecondary
        ? _frameTextureIndex(_word(parameter + 8), tsp, textures, textureList)
        : -1;
    final gouraud = isp & 0x00800000 != 0;
    final opaqueAlpha = tsp & 0x100000 == 0 ? 0xff000000 : 0;
    final state = RenderBatch.pack(
      depthCompare: isp >> 29,
      depthWrite: isp & 0x04000000 == 0,
      sourceFactor: (tsp >> 29) & 7,
      destinationFactor: (tsp >> 26) & 7,
      shading: (tsp >> 6) & 3,
      fog: (tsp >> 22) & 3,
      textureAlpha: tsp & 0x80000 == 0,
      offset: hasOffset,
    );
    _Vertex vertex(int i) =>
        _vertex(parameter + header * 4 + i * stride * 4, isp,
            ignoreShading: sourceSecondary);
    void push(_Vertex a, _Vertex b, _Vertex c) =>
        _frameClipped(a, b, c, tiles, (a, b, c) {
          out.add(_FrameTriangle(out.length, a, b, c, texture, state));
        });
    void add(_Vertex a, _Vertex b, _Vertex c) {
      final area = _edge(a, b, c.x, c.y);
      if (_culled(area, isp)) return;
      // Flat shading takes the colors of the last vertex.
      _Vertex shade(_Vertex v) =>
          _Vertex(v.x, v.y, v.z, (gouraud ? v.color : c.color) | opaqueAlpha,
              u: v.u,
              v: v.v,
              offsetColor: gouraud ? v.offsetColor : c.offsetColor);
      push(shade(a), shade(b), shade(c));
    }

    if (kind == 4) {
      add(vertex(0), vertex(1), vertex(2));
    } else if (kind == 5) {
      final a = vertex(0), b = vertex(1), c = vertex(2);
      final fourth = parameter + header * 4 + 3 * stride * 4;
      final d = _planeVertex(a, b, c, _number(fourth), _number(fourth + 4));
      if (_culled(_edge(a, b, c.x, c.y), isp)) return;
      _Vertex shade(_Vertex v) => _Vertex(v.x, v.y, v.z, v.color | opaqueAlpha,
          u: v.u, v: v.v, offsetColor: v.offsetColor);
      push(shade(a), shade(b), shade(c));
      push(shade(a), shade(c), shade(d));
    } else {
      for (var triangle = 0; triangle < 6; triangle++) {
        if (mask & (1 << (5 - triangle)) == 0) continue;
        var a = vertex(triangle), b = vertex(triangle + 1);
        final c = vertex(triangle + 2);
        if (triangle.isOdd) (a, b) = (b, a);
        add(a, b, c);
      }
    }
  }

  /// The index of the texture of [tcw] and [tsp] in [textureList], added
  /// if it is new, or -1 for a bump map.
  int _frameTextureIndex(int tcw, int tsp, Map<int, int> textures,
      List<RenderTexture> textureList) {
    final key = (tcw & 0xffffffff) | ((tsp & 0x7ffff) << 32);
    final known = textures[key];
    if (known != null) return known;
    final view = _cachedTexture(tcw, tsp);
    if (view.format == 4) return textures[key] = -1;
    textureList.add(_frameTexture(view));
    return textures[key] = textureList.length - 1;
  }

  /// Adds the background plane to [out] as two triangles over the frame,
  /// when it is textured or Gouraud shaded. The plane passes every depth
  /// test and writes no depth; the clear depth is the background depth. A
  /// flat background is the clear color.
  void _frameBackgroundPlane(int width, int height, Map<int, int> textures,
      List<RenderTexture> textureList, List<_FrameTriangle> out) {
    final tag = read(0x8c), skip = (tag >> 24) & 7;
    final parameter = read(0x20) + (((tag >> 3) & 0x1fffff) * 4);
    final isp = _word(parameter), tsp = _word(parameter + 4);
    final textured = isp & 0x02000000 != 0, gouraud = isp & 0x00800000 != 0;
    if (!textured && !gouraud || tsp & 0x02000000 != 0) return;
    final twoVolumes = tag & 0x08000000 != 0 && read(0x74) & 0x100 == 0;
    final header = twoVolumes ? 5 : 3;
    final stride = 3 + skip * (twoVolumes ? 2 : 1);
    final a = _vertex(parameter + (header + (tag & 7) * stride) * 4, isp);
    final b = _vertex(parameter + (header + ((tag & 7) + 1) * stride) * 4, isp);
    final c = _vertex(parameter + (header + ((tag & 7) + 2) * stride) * 4, isp);
    if (_edge(a, b, c.x, c.y) == 0) return;
    final texture = textured
        ? _frameTextureIndex(_word(parameter + 8), tsp, textures, textureList)
        : -1;
    final opaqueAlpha = tsp & 0x100000 == 0 ? 0xff000000 : 0;
    final state = RenderBatch.pack(
      depthCompare: 7,
      depthWrite: false,
      sourceFactor: 1,
      destinationFactor: 0,
      shading: (tsp >> 6) & 3,
      fog: (tsp >> 22) & 3,
      textureAlpha: tsp & 0x80000 == 0,
      offset: textured && isp & 0x01000000 != 0,
    );
    // Flat shading takes the colors of the last vertex.
    _Vertex flat(_Vertex v) => gouraud
        ? v
        : _Vertex(v.x, v.y, v.z, c.color,
            u: v.u, v: v.v, offsetColor: c.offsetColor);
    final fa = flat(a), fb = flat(b);
    _Vertex corner(double x, double y) {
      final v = _planeVertex(fa, fb, c, x, y);
      return _Vertex(v.x, v.y, v.z, v.color | opaqueAlpha,
          u: v.u, v: v.v, offsetColor: v.offsetColor);
    }

    // The plane reaches colors out of range outside its triangle. The
    // screen is cut where a channel crosses 0 or 255, so that the colors
    // clamped at the corners of each piece interpolate like the plane.
    final w = width.toDouble(), h = height.toDouble();
    var pieces = [
      [(0.0, 0.0), (w, 0.0), (w, h), (0.0, h)]
    ];
    final area = _edge(fa, fb, c.x, c.y);
    for (final (pa, pb, pc) in [
      (fa.color, fb.color, c.color),
      if (textured && isp & 0x01000000 != 0)
        (fa.offsetColor, fb.offsetColor, c.offsetColor),
    ]) {
      for (var shift = 0; shift < 32; shift += 8) {
        for (final bound in [0, 255]) {
          // The channel minus the bound, times the interpolated depth: a
          // linear function of the screen position.
          double f((double, double) p) {
            final (x, y) = p;
            final la = _edge(fb, c, x, y) / area;
            final lb = _edge(c, fa, x, y) / area;
            return la * fa.z * (((pa >> shift) & 255) - bound) +
                lb * fb.z * (((pb >> shift) & 255) - bound) +
                (1 - la - lb) * c.z * (((pc >> shift) & 255) - bound);
          }

          pieces = [for (final p in pieces) ..._split(p, f)];
        }
      }
    }
    for (final piece in pieces) {
      final corners = [for (final (x, y) in piece) corner(x, y)];
      for (var i = 2; i < corners.length; i++) {
        out.add(_FrameTriangle(
            out.length, corners[0], corners[i - 1], corners[i], texture, state,
            background: true));
      }
    }
  }

  /// The parts of the convex [polygon] where [f] is not negative and where
  /// it is not positive, leaving out parts without area.
  static List<List<(double, double)>> _split(List<(double, double)> polygon,
      double Function((double, double)) f) {
    final values = [for (final p in polygon) f(p)];
    if (values.every((v) => v >= 0) || values.every((v) => v <= 0)) {
      return [polygon];
    }
    final positive = <(double, double)>[], negative = <(double, double)>[];
    for (var i = 0; i < polygon.length; i++) {
      final j = (i + 1) % polygon.length;
      final p = polygon[i], vp = values[i], vq = values[j];
      if (vp >= 0) positive.add(p);
      if (vp <= 0) negative.add(p);
      if (vp < 0 && vq > 0 || vp > 0 && vq < 0) {
        final t = vp / (vp - vq), q = polygon[j];
        final cut = (p.$1 + (q.$1 - p.$1) * t, p.$2 + (q.$2 - p.$2) * t);
        positive.add(cut);
        negative.add(cut);
      }
    }
    return [
      if (positive.length >= 3) positive,
      if (negative.length >= 3) negative,
    ];
  }

  /// Passes the triangle [a], [b], [c] to [emit], clipped to the pixels of
  /// the tile rectangle [tiles], as a fan of triangles with the attributes
  /// of the plane of the triangle.
  void _frameClipped(_Vertex a, _Vertex b, _Vertex c, int tiles,
      void Function(_Vertex, _Vertex, _Vertex) emit) {
    final left = (tiles & 255) * 32.0, top = ((tiles >> 8) & 255) * 32.0;
    final right = (((tiles >> 16) & 255) + 1) * 32.0;
    final bottom = (((tiles >> 24) & 255) + 1) * 32.0;
    bool inside(_Vertex v) =>
        v.x >= left && v.x <= right && v.y >= top && v.y <= bottom;
    if (inside(a) && inside(b) && inside(c)) return emit(a, b, c);
    if (_edge(a, b, c.x, c.y) == 0) return;
    var polygon = [a, b, c];
    // One edge of the rectangle at a time: [value] is the coordinate that
    // the edge bounds, [keep] whether a point is on the inner side.
    for (final (horizontal, limit, low) in [
      (true, left, true),
      (true, right, false),
      (false, top, true),
      (false, bottom, false),
    ]) {
      double value(_Vertex v) => horizontal ? v.x : v.y;
      bool keep(_Vertex v) => low ? value(v) >= limit : value(v) <= limit;
      final result = <_Vertex>[];
      for (var i = 0; i < polygon.length; i++) {
        final p = polygon[i], q = polygon[(i + 1) % polygon.length];
        if (keep(p)) result.add(p);
        if (keep(p) != keep(q)) {
          final t = (limit - value(p)) / (value(q) - value(p));
          final x = horizontal ? limit : p.x + (q.x - p.x) * t;
          final y = horizontal ? p.y + (q.y - p.y) * t : limit;
          result.add(_planeVertex(a, b, c, x, y));
        }
      }
      polygon = result;
      if (polygon.length < 3) return;
    }
    for (var i = 1; i + 1 < polygon.length; i++) {
      emit(polygon[0], polygon[i], polygon[i + 1]);
    }
  }

  /// The vertex at [x], [y] on the plane of [a], [b] and [c], with the
  /// perspective-correct attributes of that plane.
  _Vertex _planeVertex(_Vertex a, _Vertex b, _Vertex c, double x, double y) {
    final area = _edge(a, b, c.x, c.y);
    final la = _edge(b, c, x, y) / area, lb = _edge(c, a, x, y) / area;
    final lc = 1 - la - lb;
    final z = la * a.z + lb * b.z + lc * c.z;
    double at(double pa, double pb, double pc) =>
        (la * pa * a.z + lb * pb * b.z + lc * pc * c.z) / z;
    int color(int ca, int cb, int cc) {
      var result = 0;
      for (var shift = 0; shift < 32; shift += 8) {
        final v = at(((ca >> shift) & 255) + 0.0, ((cb >> shift) & 255) + 0.0,
                ((cc >> shift) & 255) + 0.0)
            .round()
            .clamp(0, 255);
        result |= v << shift;
      }
      return result;
    }

    return _Vertex(x, y, z, color(a.color, b.color, c.color),
        u: at(a.u, b.u, c.u),
        v: at(a.v, b.v, c.v),
        offsetColor: color(a.offsetColor, b.offsetColor, c.offsetColor));
  }

  RenderTexture _frameTexture(DcGpuTexture view) {
    final width = view.width, height = view.height;
    final cache = view.cache;
    final kept = cache == null ? null : _frameTexels[cache];
    final Uint8List rgba;
    if (kept != null && kept.$1 == cache!.changes) {
      rgba = kept.$2;
    } else {
      rgba = Uint8List(width * height * 4);
      final words = Uint32List.view(rgba.buffer);
      if (cache != null) {
        // The decoded texels of the cache, from ARGB to RGBA bytes, kept
        // until the cache changes.
        view.decodeAll();
        final texels = cache.texels;
        for (var i = 0; i < words.length; i++) {
          final t = texels[i];
          words[i] = (t & 0xff00ff00) | ((t >> 16) & 0xff) | ((t & 0xff) << 16);
        }
        _frameTexels[cache] = (cache.changes, rgba);
      } else {
        var i = 0;
        for (var y = 0; y < height; y++) {
          for (var x = 0; x < width; x++) {
            final t = view.texelAt(x, y);
            words[i++] =
                (t & 0xff00ff00) | ((t >> 16) & 0xff) | ((t & 0xff) << 16);
          }
        }
      }
    }
    int address(bool clamp, bool flip) => clamp ? 2 : (flip ? 1 : 0);
    return RenderTexture(
        width: width,
        height: height,
        sampler: (view.bilinear ? 1 : 0) |
            (address(view.clampU, view.flipU) << 1) |
            (address(view.clampV, view.flipV) << 3),
        rgba: rgba);
  }

  /// The color and the depth of the background, taken as a clear color.
  (int, double) _frameBackground() {
    final tag = read(0x8c), skip = (tag >> 24) & 7;
    final parameter = read(0x20) + (((tag >> 3) & 0x1fffff) * 4);
    final isp = _word(parameter), tsp = _word(parameter + 4);
    final depth = _value(read(0x88));
    final shadow = tag & 0x08000000 != 0;
    final twoVolumes = shadow && read(0x74) & 0x100 == 0;
    final header = twoVolumes ? 5 : 3;
    final stride = 3 + skip * (twoVolumes ? 2 : 1);
    final textured = isp & 0x02000000 != 0, gouraud = isp & 0x00800000 != 0;
    final vertex = (tag & 7) + (textured || gouraud ? 0 : 2);
    final textureWords = textured ? (isp & 0x00400000 != 0 ? 1 : 2) : 0;
    var color =
        _word(parameter + (header + vertex * stride + 3 + textureWords) * 4);
    if (tsp & 0x100000 == 0) color |= 0xff000000;
    return (fog.apply(color, depth, 0, tsp, hasOffset: false), depth);
  }

  /// Copies the colors of the tile at [originX], [originY] into the
  /// reference image of the captured frame.
  void _frameReference(int originX, int originY) {
    final frame = _capturing!, reference = frame.reference!;
    for (var y = 0; y < 32; y++) {
      final py = originY + y;
      if (py >= frame.height) break;
      for (var x = 0; x < 32; x++) {
        final px = originX + x;
        if (px >= frame.width) break;
        reference[py * frame.width + px] = _colors[y * 32 + x];
      }
    }
  }

  /// The tiles that a render writes and the registers that select where and
  /// how, read when the render starts.
  _FrameOutput _frameOutput() {
    final type2 = read(0x7c) & 0x200000 != 0;
    final tiles = <int>{};
    var regions = 0;
    for (var region = read(0x2c);; region += type2 ? 24 : 20) {
      final control = _word(region);
      regions++;
      if (control & 0x10000000 == 0) {
        tiles.add(((control >> 2) & 63) | (((control >> 8) & 63) << 6));
      }
      if (control & 0x80000000 != 0) break;
    }
    return _FrameOutput([for (final o in _FrameOutput.offsets) read(o)],
        tiles.toList(), regions);
  }

  /// Writes the RGBA pixels that the host drew for [frame] to VRAM, as the
  /// tiles of [output] with the registers of the render.
  void _writeFrame(_FrameOutput output, RenderFrame frame, Uint8List rgba) {
    final width = frame.width, height = frame.height;
    if (rgba.length < width * height * 4) return;
    final offsets = _FrameOutput.offsets;
    final saved = [for (final o in offsets) _registerWords[o >> 2]];
    final savedColors = Uint32List.fromList(_colors);
    final stripLines = _stripLines, capturing = _capturing;
    try {
      for (var i = 0; i < offsets.length; i++) {
        _registerWords[offsets[i] >> 2] = output.registers[i];
      }
      _stripLines = 0;
      _capturing = null;
      final pixels = rgba.offsetInBytes & 3 == 0
          ? Uint32List.view(rgba.buffer, rgba.offsetInBytes, width * height)
          : Uint32List.view(Uint8List.fromList(rgba).buffer);
      final colors = _colors;
      for (final tile in output.tiles) {
        final originX = (tile & 63) * 32, originY = (tile >> 6) * 32;
        final columns = math.max(0, math.min(32, width - originX));
        for (var y = 0; y < 32; y++) {
          final py = originY + y, row = y * 32;
          if (py >= height) {
            colors.fillRange(row, row + 32, 0);
            continue;
          }
          final first = py * width + originX;
          for (var x = 0; x < columns; x++) {
            // RGBA bytes to ARGB.
            final p = pixels[first + x];
            colors[row + x] =
                (p & 0xff00ff00) | ((p >> 16) & 0xff) | ((p & 0xff) << 16);
          }
          if (columns < 32) colors.fillRange(row + columns, row + 32, 0);
        }
        _writeTile(originX, originY);
      }
    } finally {
      for (var i = 0; i < offsets.length; i++) {
        _registerWords[offsets[i] >> 2] = saved[i];
      }
      _stripLines = stripLines;
      _capturing = capturing;
      _colors.setAll(0, savedColors);
    }
  }
}

/// See [_FrameBuilder._frameOutput].
class _FrameOutput {
  _FrameOutput(this.registers, this.tiles, this.regions);

  /// The registers that [DcGpuRender._writeTile] reads.
  static const offsets = [0x48, 0x4c, 0x60, 0x64, 0x68, 0x6c, 0xf4];
  final List<int> registers;

  /// The written tiles as x | y << 6, and the number of region entries.
  final List<int> tiles;
  final int regions;
}
