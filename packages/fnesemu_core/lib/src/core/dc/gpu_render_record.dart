part of 'gpu_render.dart';

// The CPU half of a render on a compute program: the region array and the
// object lists are walked as [DcGpuRender._tile] walks them, with the same
// checks, and each triangle that is not culled becomes a record of edge and
// plane equations in the coordinates of its tile. The GPU half is in
// dc_compute_shader.dart; it shades each pixel of a tile from these records.

extension on DcGpuRender {
  /// Records every region entry of the render from the current one, and
  /// submits it. An entry whose lists fail a check keeps the error, which
  /// [_tile] throws when it reaches that entry.
  void _recordRender(DcCompute compute) {
    final frame = compute.frame..clear();
    _recording = frame;
    _computeIndex = 0;
    try {
      frame.constants(
          palette: palette,
          fog: fog,
          control: read(0x80),
          shadow: read(0x74),
          alphaReference: read(0x11c));
      final type2 = read(0x7c) & 0x200000 != 0;
      var region = _region;
      for (;;) {
        final control = _word(region);
        try {
          _recordEntry(frame, region, control, type2);
        } on DcUnsupported catch (error) {
          frame.fail(error);
          break;
        }
        if (control & 0x80000000 != 0) break;
        region += type2 ? 24 : 20;
      }
    } on DcUnsupported catch (error) {
      frame.fail(error);
    } finally {
      _recording = null;
      _sortMode = 0;
      _materialArea = _shadowArea = -1;
    }
    compute.submit();
  }

  void _recordEntry(DcComputeFrame frame, int region, int control, bool type2) {
    _primitiveOrder = 0;
    final x = (control >> 2) & 63, y = (control >> 8) & 63;
    final originX = x * 32, originY = y * 32;
    final drawsBackground = control & 0x40000000 == 0;
    final backgroundShadow = drawsBackground && read(0x8c) & 0x08000000 != 0;
    final opaque = _word(region + 4);
    final opaqueModifier = _nonEmptyModifier(_word(region + 8));
    final translucent = _word(region + 12),
        translucentModifier = _nonEmptyModifier(_word(region + 16));
    final punch = type2 ? _word(region + 20) : 0x80000000;
    var mode = 0;
    if (translucent & 0x80000000 == 0) {
      final presort = type2 ? control & 0x20000000 != 0 : read(0x98) & 1 != 0;
      if (presort) {
        if (translucentModifier & 0x80000000 == 0) {
          throw const DcUnsupported(
              'CORE translucent modifiers require auto-sort');
        }
        mode = 1;
      } else {
        mode = translucentModifier & 0x80000000 == 0 ? 3 : 2;
      }
    }
    final hasModifier = opaqueModifier & 0x80000000 == 0;
    frame.beginEntry(
        drawsBackground: drawsBackground,
        backgroundShadow: backgroundShadow && hasModifier,
        opaqueModifier: hasModifier,
        translucentMode: mode,
        writes: control & 0x10000000 == 0,
        backgroundDepth: drawsBackground ? _value(read(0x88)) : 0);
    frame.section(DcComputeFrame.backgroundList);
    if (drawsBackground) _background(originX, originY);
    frame.section(DcComputeFrame.opaqueList);
    _sortMode = 0;
    if (opaque & 0x80000000 == 0) {
      _objects(opaque & 0xfffffc, originX, originY);
    }
    frame.section(DcComputeFrame.punchList);
    if (punch & 0x80000000 == 0) {
      _sortMode = 2;
      _primitiveOrder = 0;
      _objects(punch & 0xfffffc, originX, originY);
    }
    frame.section(DcComputeFrame.translucentList);
    if (mode == 1) {
      _sortMode = 0;
      _objects(translucent & 0xfffffc, originX, originY);
    } else if (mode != 0) {
      _sortMode = mode == 2 ? 3 : 4;
      _primitiveOrder = 0;
      _objects(translucent & 0xfffffc, originX, originY);
    }
    _sortMode = 0;
    frame.section(DcComputeFrame.opaqueModifierList);
    if (hasModifier) {
      _recordModifier(frame, opaqueModifier & 0xfffffc, originX, originY);
    }
    frame.section(DcComputeFrame.translucentModifierList);
    if (mode == 3) {
      _recordModifier(frame, translucentModifier & 0xfffffc, originX, originY);
    }
    frame.endEntry();
  }

  void _recordModifier(
      DcComputeFrame frame, int list, int originX, int originY) {
    final offset = read(0x80) & 1 != 0 ? 0.5 : 0.0;
    modifier.walk(list, read(0x20), (vertices, plane) {
      frame.modifierTriangle(vertices, plane, originX, originY, offset);
    }, frame.modifierClose);
  }

  /// [_triangle] while recording: the triangle after its cull test and
  /// winding, with the vertices of its shading plane.
  void _recordTriangle(
      DcComputeFrame frame,
      _Vertex a,
      _Vertex b,
      _Vertex c,
      _Vertex sa,
      _Vertex sb,
      _Vertex sc,
      double shadeArea,
      int isp,
      int tsp,
      DcGpuTexture? texture,
      Float64List? mipNumerators,
      int order,
      bool plane,
      double? backgroundDepth,
      int originX,
      int originY) {
    final offset = read(0x80) & 1 != 0 ? 0.5 : 0.0;
    final minX = math.min(math.min(a.x, b.x), c.x),
        maxX = math.max(math.max(a.x, b.x), c.x),
        minY = math.min(math.min(a.y, b.y), c.y),
        maxY = math.max(math.max(a.y, b.y), c.y);
    final left = DcGpuRender._tileFloor(minX - originX - offset);
    final right = DcGpuRender._tileCeiling(maxX - originX - offset);
    final top = DcGpuRender._tileFloor(minY - originY - offset);
    final bottom = DcGpuRender._tileCeiling(maxY - originY - offset);
    if (left >= right || top >= bottom) return;
    final r = frame.addRecord();
    final words = frame.records, floats = frame.recordFloats;
    words[r] = isp;
    words[r + 1] = tsp;
    words[r + 2] = texture == null ? 0xffffffff : frame.texture(texture, tsp);
    words[r + 3] = order;
    words[r + 4] = ((_materialArea + 1) & 3) |
        (((_shadowArea + 1) & 3) << 2) |
        (_shadowObject ? 16 : 0) |
        (plane ? 32 : 0) |
        (backgroundDepth != null ? 64 : 0) |
        (_topLeft(b, c) ? 0x100 : 0) |
        (_topLeft(c, a) ? 0x200 : 0) |
        (_topLeft(a, b) ? 0x400 : 0);
    words[r + 5] = left | (right << 8) | (top << 16) | (bottom << 24);
    frame.edge(r + 6, b.x, b.y, c.x, c.y, originX, originY);
    frame.edge(r + 9, c.x, c.y, a.x, a.y, originX, originY);
    frame.edge(r + 12, a.x, a.y, b.x, b.y, originX, originY);
    // The weights of the shading plane as linear functions of the position.
    final inverse = 1 / shadeArea;
    final ax = (sb.y - sc.y) * inverse,
        ay = (sc.x - sb.x) * inverse,
        a0 = ((sc.y - sb.y) * sb.x - (sc.x - sb.x) * sb.y) * inverse;
    final bx = (sc.y - sa.y) * inverse,
        by = (sa.x - sc.x) * inverse,
        b0 = ((sa.y - sc.y) * sc.x - (sa.x - sc.x) * sc.y) * inverse;
    final cx = (sa.y - sb.y) * inverse,
        cy = (sb.x - sa.x) * inverse,
        c0 = ((sb.y - sa.y) * sa.x - (sb.x - sa.x) * sa.y) * inverse;
    void planeOf(int at, double pa, double pb, double pc) {
      floats[at] = pa * ax + pb * bx + pc * cx;
      floats[at + 1] = pa * ay + pb * by + pc * cy;
      floats[at + 2] = pa * (a0 + ax * originX + ay * originY) +
          pb * (b0 + bx * originX + by * originY) +
          pc * (c0 + cx * originX + cy * originY);
    }

    final za = sa.z, zb = sb.z, zc = sc.z;
    planeOf(r + 15, za, zb, zc);
    planeOf(r + 18, sa.u * za, sb.u * zb, sc.u * zc);
    planeOf(r + 21, sa.v * za, sb.v * zb, sc.v * zc);
    planeOf(r + 24, za, 0, 0);
    planeOf(r + 27, 0, zb, 0);
    planeOf(r + 30, 0, 0, zc);
    words[r + 33] = sa.color;
    words[r + 34] = sb.color;
    words[r + 35] = sc.color;
    words[r + 36] = sa.offsetColor;
    words[r + 37] = sb.offsetColor;
    words[r + 38] = sc.offsetColor;
    if (mipNumerators != null) {
      for (var i = 0; i < 4; i++) {
        floats[r + 39 + i] = mipNumerators[i];
      }
    }
    floats[r + 43] = backgroundDepth ?? 0;
  }
}
