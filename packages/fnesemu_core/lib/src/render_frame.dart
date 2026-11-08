import 'dart:typed_data';

/// One render of 3D primitives, prepared for a host GPU.
///
/// A core builds a frame when its renderer starts and passes it to a
/// [RenderFrameSink]. The core does not wait for the host GPU. Positions are
/// in pixels of the render target, with y down. The depth of a vertex is the
/// reciprocal of its w and grows toward the viewer; [depthScale] maps every
/// depth of the frame into 0 to 1.
class RenderFrame {
  RenderFrame({
    required this.width,
    required this.height,
    required this.clearColor,
    required this.clearDepth,
    required this.depthScale,
    required this.vertices,
    required this.batches,
    required this.textures,
    required this.fogTable,
    required this.fogScale,
    required this.fogColor,
    required this.vertexFogColor,
    required this.alphaReference,
    this.target = 0,
  });

  /// The floats of one vertex in [vertices]: x, y, depth, u, v, the base
  /// color as red, green, blue and alpha in 0 to 1, and the offset color in
  /// the same order.
  static const vertexFloats = 13;

  final int width, height;

  /// ARGB color and depth of the pixels that no primitive covers.
  final int clearColor;
  final double clearDepth;
  final double depthScale;

  /// Three vertices per triangle, [vertexFloats] floats per vertex.
  final Float32List vertices;
  final List<RenderBatch> batches;
  final List<RenderTexture> textures;

  /// 128 fog entries as pairs of bytes: the value at the entry and at the
  /// next one. A depth times [fogScale] selects the entry as in
  /// [fogPosition].
  final Uint8List fogTable;
  final double fogScale;

  /// RGB of the table fog and of the vertex fog.
  final int fogColor, vertexFogColor;

  /// Punch-through fragments with a smaller alpha are dropped.
  final int alphaReference;

  /// The address that the core writes the render to, for diagnostics.
  final int target;

  /// ARGB pixels of the same render by the core's own renderer, row by row,
  /// if the core was asked for them.
  Uint32List? reference;

  /// Set by a core that leaves the drawing of the frame to the host. The
  /// host calls it with the drawn frame as RGBA bytes, row by row, and the
  /// core writes them to its video memory. The core does not wait for it.
  void Function(Uint8List rgba)? onDrawn;

  int get triangleCount => vertices.length ~/ (vertexFloats * 3);

  /// The table entry and the fraction toward the next one at [depth].
  static (int, double) fogPosition(double depth, double scale) {
    final scaled = depth * scale;
    var mantissa = scaled < 255.9999 ? (scaled > 1.0 ? scaled : 1.0) : 255.9999;
    var index = 0;
    while (mantissa >= 2) {
      mantissa *= 0.5;
      index += 16;
    }
    final position = (mantissa - 1) * 16;
    final whole = position.toInt();
    return (index + whole, position - whole);
  }

  static const _magic = 0x4d524652, _version = 1;

  Uint8List encode() {
    final out = BytesBuilder(copy: false);
    final header = ByteData(64);
    var o = 0;
    void int32(int v) {
      header.setInt32(o, v, Endian.little);
      o += 4;
    }

    void float64(double v) {
      header.setFloat64(o, v, Endian.little);
      o += 8;
    }

    int32(_magic);
    int32(_version);
    int32(width);
    int32(height);
    int32(clearColor);
    float64(clearDepth);
    float64(depthScale);
    float64(fogScale);
    int32(fogColor);
    int32(vertexFogColor);
    int32(alphaReference);
    int32(target);
    out.add(header.buffer.asUint8List(0, o));
    void words(List<int> values) {
      final data = ByteData(values.length * 4);
      for (var i = 0; i < values.length; i++) {
        data.setInt32(i * 4, values[i], Endian.little);
      }
      out.add(data.buffer.asUint8List());
    }

    void bytes(Uint8List data) {
      words([data.length]);
      out.add(data);
      final pad = (-data.length) & 3;
      if (pad != 0) out.add(Uint8List(pad));
    }

    bytes(fogTable);
    bytes(vertices.buffer
        .asUint8List(vertices.offsetInBytes, vertices.lengthInBytes));
    words([batches.length]);
    for (final b in batches) {
      words([b.pass, b.first, b.count, b.texture, b.state]);
    }
    words([textures.length]);
    for (final t in textures) {
      words([t.width, t.height, t.sampler]);
      bytes(t.rgba);
    }
    final r = reference;
    bytes(r == null
        ? Uint8List(0)
        : r.buffer.asUint8List(r.offsetInBytes, r.lengthInBytes));
    return out.takeBytes();
  }

  static RenderFrame decode(Uint8List data) {
    final view = ByteData.sublistView(data);
    var o = 0;
    int int32() {
      final v = view.getInt32(o, Endian.little);
      o += 4;
      return v;
    }

    double float64() {
      final v = view.getFloat64(o, Endian.little);
      o += 8;
      return v;
    }

    Uint8List bytes() {
      final length = int32();
      final result = Uint8List.fromList(data.sublist(o, o + length));
      o += (length + 3) & ~3;
      return result;
    }

    if (int32() != _magic || int32() != _version) {
      throw const FormatException('not a render frame of this version');
    }
    final width = int32(), height = int32(), clearColor = int32();
    final clearDepth = float64(), depthScale = float64(), fogScale = float64();
    final fogColor = int32(), vertexFogColor = int32();
    final alphaReference = int32(), target = int32();
    final fogTable = bytes();
    final vertices = bytes().buffer.asFloat32List();
    final batches = [
      for (var i = int32(); i > 0; i--)
        RenderBatch(
            pass: int32(),
            first: int32(),
            count: int32(),
            texture: int32(),
            state: int32()),
    ];
    final textures = [
      for (var i = int32(); i > 0; i--)
        RenderTexture(
            width: int32(), height: int32(), sampler: int32(), rgba: bytes()),
    ];
    final reference = bytes();
    return RenderFrame(
      width: width,
      height: height,
      clearColor: clearColor & 0xffffffff,
      clearDepth: clearDepth,
      depthScale: depthScale,
      vertices: vertices,
      batches: batches,
      textures: textures,
      fogTable: fogTable,
      fogScale: fogScale,
      fogColor: fogColor,
      vertexFogColor: vertexFogColor,
      alphaReference: alphaReference,
      target: target,
    )..reference = reference.isEmpty ? null : reference.buffer.asUint32List();
  }
}

/// Consecutive triangles of a frame drawn with one state.
class RenderBatch {
  const RenderBatch({
    required this.pass,
    required this.first,
    required this.count,
    required this.texture,
    required this.state,
  });

  /// The batches of a frame come in this order of passes: opaque,
  /// punch-through, volume, inside opaque, inside punch-through and
  /// translucent.
  ///
  /// A volume batch holds closed volumes. A pixel is inside a volume when
  /// an odd number of its triangles cover the pixel at or in front of the
  /// stored depth; see [volumeLayer]. Volume triangles draw no color and no
  /// depth.
  ///
  /// Inside batches replace the opaque and punch-through triangles in the
  /// pixels inside the volumes: they are drawn only there, and only where
  /// their depth equals the stored depth.
  static const opaque = 0,
      punchThrough = 1,
      translucent = 2,
      volume = 3,
      insideOpaque = 4,
      insidePunchThrough = 5;

  final int pass;

  /// The first triangle and the number of triangles.
  final int first, count;

  /// The index in [RenderFrame.textures], or -1.
  final int texture;

  /// The packed state; see the getters.
  final int state;

  /// How the volumes of a group change the inside area: 1 adds the pixels
  /// inside any of them, 2 keeps only the pixels outside all of them.
  int get volumeInstruction => state & 3;

  /// The layer, 0 to 6, that holds the parity of the volumes of a volume
  /// batch. The volumes of a layer do not cover the same pixels. A group
  /// of volumes takes consecutive batches with layers from 0 up, and its
  /// last batch has [volumeGroupEnds].
  int get volumeLayer => (state >> 2) & 7;
  bool get volumeGroupEnds => state & 32 != 0;

  /// [depthCompare] values: never, less, equal, less or equal, greater, not
  /// equal, greater or equal, always. A fragment passes when its depth
  /// compares so with the stored depth.
  int get depthCompare => state & 7;
  bool get depthWrite => state & 8 != 0;

  /// Blend factors of the translucent pass: zero, one, the other color, one
  /// minus the other color, source alpha, one minus source alpha,
  /// destination alpha, one minus destination alpha. The other color of the
  /// source factor is the destination color, and the reverse.
  int get sourceFactor => (state >> 4) & 7;
  int get destinationFactor => (state >> 7) & 7;

  /// Texture shading: decal, modulate, decal with alpha, modulate with
  /// alpha.
  int get shading => (state >> 10) & 3;

  /// Fog: table, vertex, none, table alpha.
  int get fog => (state >> 12) & 3;
  bool get textureAlpha => state & 0x4000 != 0;
  bool get offset => state & 0x8000 != 0;

  static int pack({
    required int depthCompare,
    required bool depthWrite,
    required int sourceFactor,
    required int destinationFactor,
    required int shading,
    required int fog,
    required bool textureAlpha,
    required bool offset,
  }) =>
      depthCompare |
      (depthWrite ? 8 : 0) |
      (sourceFactor << 4) |
      (destinationFactor << 7) |
      (shading << 10) |
      (fog << 12) |
      (textureAlpha ? 0x4000 : 0) |
      (offset ? 0x8000 : 0);
}

/// Decoded texels of one texture, in RGBA bytes row by row.
class RenderTexture {
  const RenderTexture({
    required this.width,
    required this.height,
    required this.sampler,
    required this.rgba,
  });

  final int width, height;

  /// Bit 0: bilinear filter. Bits 1-2 and 3-4: the u and v address modes,
  /// repeat (0), mirror (1) or clamp (2).
  final int sampler;
  final Uint8List rgba;

  bool get bilinear => sampler & 1 != 0;
  int get addressU => (sampler >> 1) & 3;
  int get addressV => (sampler >> 3) & 3;
}

/// Receives the frames of a core's renderer.
abstract interface class RenderFrameSink {
  void submit(RenderFrame frame);
}
