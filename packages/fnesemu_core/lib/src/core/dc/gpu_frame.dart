part of 'gpu_render.dart';

/// A triangle of a [RenderFrame] before batching.
class _FrameTriangle {
  _FrameTriangle(this.order, this.a, this.b, this.c, this.texture, this.state);
  final int order, texture, state;
  final _Vertex a, b, c;
  double get depth => (a.z + b.z + c.z) / 3;
}

/// Builds the [RenderFrame] of a render from the region array and the
/// object lists, for a host GPU. Every object is taken once, however many
/// tiles list it. This is a functional approximation: modifier volumes, the
/// secondary accumulation buffer, bump maps, MIP levels and the color clamp
/// are left out, the background is a clear color, and auto-sorted
/// translucent triangles are ordered by their mean depth.
extension _FrameBuilder on DcGpuRender {
  RenderFrame _buildFrame() {
    final type2 = read(0x7c) & 0x200000 != 0;
    final lists = [<int>{}, <int>{}, <int>{}];
    var presort = false, first = true, tilesX = 0, tilesY = 0;
    for (var region = read(0x2c);; region += type2 ? 24 : 20) {
      final control = _word(region);
      final tx = ((control >> 2) & 63) + 1, ty = ((control >> 8) & 63) + 1;
      if (tx > tilesX) tilesX = tx;
      if (ty > tilesY) tilesY = ty;
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
        if (pointer & 0x80000000 == 0) lists[pass].add(pointer & 0xfffffc);
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
    for (var pass = 0; pass < 3; pass++) {
      // The parameters of each object with the union of its strip masks.
      final objects = <int, (int, int)>{};
      for (final list in lists[pass]) {
        _frameObjects(list, objects);
      }
      final addresses = objects.keys.toList()..sort();
      for (final parameter in addresses) {
        final (pointer, mask) = objects[parameter]!;
        _frameObject(parameter, pointer, mask, pass, textures, textureList,
            triangles[pass]);
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
          if (v.z > maximumDepth) maximumDepth = v.z;
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
      width: math.min(tilesX * 32, ((read(0x68) >> 16) & 0x7ff) + 1),
      height: math.min(tilesY * 32, ((read(0x6c) >> 16) & 0x3ff) + 1),
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

  void _frameObjects(int address, Map<int, (int, int)> objects) {
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
        objects[parameter] = (pointer, (previous?.$2 ?? 0) | mask);
        continue;
      }
      if (kind != 4 && kind != 5) continue;
      final count = ((pointer >> 25) & 15) + 1;
      for (var i = 0; i < count; i++) {
        objects[parameter] = (pointer, 0);
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
    var texture = -1;
    if (textured && !sourceSecondary) {
      final tcw = _word(parameter + 8);
      final key = (tcw & 0xffffffff) | ((tsp & 0x7ffff) << 32);
      texture = textures[key] ?? -1;
      if (!textures.containsKey(key)) {
        final view = _cachedTexture(tcw, tsp);
        if (view.format != 4) {
          texture = textures[key] = textureList.length;
          textureList.add(_frameTexture(view));
        } else {
          textures[key] = -1;
        }
      }
    }
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
    void add(_Vertex a, _Vertex b, _Vertex c) {
      final area = _edge(a, b, c.x, c.y);
      if (_culled(area, isp)) return;
      // Flat shading takes the colors of the last vertex.
      _Vertex shade(_Vertex v) =>
          _Vertex(v.x, v.y, v.z, (gouraud ? v.color : c.color) | opaqueAlpha,
              u: v.u,
              v: v.v,
              offsetColor: gouraud ? v.offsetColor : c.offsetColor);
      out.add(_FrameTriangle(
          out.length, shade(a), shade(b), shade(c), texture, state));
    }

    if (kind == 4) {
      add(vertex(0), vertex(1), vertex(2));
    } else if (kind == 5) {
      final a = vertex(0), b = vertex(1), c = vertex(2);
      final fourth = parameter + header * 4 + 3 * stride * 4;
      final d = _planeVertex(a, b, c, _number(fourth), _number(fourth + 4));
      if (_culled(_edge(a, b, c.x, c.y), isp)) return;
      out.add(_FrameTriangle(out.length, a, b, c, texture, state));
      out.add(_FrameTriangle(out.length, a, c, d, texture, state));
      for (var i = out.length - 2; i < out.length; i++) {
        final t = out[i];
        _Vertex shade(_Vertex v) =>
            _Vertex(v.x, v.y, v.z, v.color | opaqueAlpha,
                u: v.u, v: v.v, offsetColor: v.offsetColor);
        out[i] = _FrameTriangle(
            t.order, shade(t.a), shade(t.b), shade(t.c), t.texture, t.state);
      }
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
    final rgba = Uint8List(width * height * 4);
    var o = 0;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final texel = view.texelAt(x, y);
        rgba[o++] = (texel >> 16) & 255;
        rgba[o++] = (texel >> 8) & 255;
        rgba[o++] = texel & 255;
        rgba[o++] = (texel >> 24) & 255;
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
}
