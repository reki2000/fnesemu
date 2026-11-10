import 'dart:async';
import 'dart:typed_data';

import 'package:fnesemu_core/app_api.dart';
import 'package:mp_gpu/mp_gpu.dart';

/// Draws [RenderFrame]s on a [GpuDevice] into offscreen targets.
///
/// This is a first, plain implementation: every frame uploads its vertices
/// and its textures and draws each batch with its own state.
class FrameRenderer {
  FrameRenderer._(this.device, this._program)
      : _white = device.texture(1, 1, Uint8List.fromList([255, 255, 255, 255])),
        _fragmentStride = (_fragmentBytes + device.uniformAlignment - 1) ~/
            device.uniformAlignment *
            device.uniformAlignment;

  static const _source = GpuProgramSource(
    bundle: 'packages/render_frame_gpu/shaders/frame.shaderbundle',
    vertexEntry: 'FrameVertex',
    fragmentEntry: 'FrameFragment',
    wgsl: 'packages/render_frame_gpu/shaders/frame.wgsl',
    attributes: [3, 2, 4, 4],
    bindings: [
      GpuBinding.uniform('FrameInfo', 0, vertex: true),
      GpuBinding.uniform('FragmentInfo', 1),
      GpuBinding.texture('texture_sampler', 2),
      GpuBinding.texture('fog_table', 4),
    ],
  );

  static Future<FrameRenderer> create(GpuDevice device) async =>
      FrameRenderer._(device, await device.program(_source));

  final GpuDevice device;
  final GpuProgram _program;
  final GpuTexture _white;

  RenderFrame? _prepared;
  List<GpuTexture> _textures = const [];
  List<GpuSampler> _samplers = const [];
  final _uploaded = Expando<GpuTexture>();
  GpuTexture? _fog;
  // The fog table that [_fog] holds.
  final _fogTable = Uint8List(256);

  /// Uploads the textures and the fog table of [frame]. A texture whose
  /// texels are the same list as in an earlier frame is not uploaded again,
  /// and neither is a fog table with the same entries as the last one.
  void prepare(RenderFrame frame) {
    if (identical(frame, _prepared)) return;
    _textures = [
      for (final t in frame.textures)
        _uploaded[t.rgba] ??= device.texture(t.width, t.height, t.rgba)
    ];
    _samplers = [
      for (final t in frame.textures)
        GpuSampler(
            linear: t.bilinear,
            addressU: _address(t.addressU),
            addressV: _address(t.addressV))
    ];
    _prepared = frame;
    final table = frame.fogTable;
    if (_fog != null && _sameFog(table)) return;
    _fogTable.setAll(0, table);
    final fog = Uint8List(128 * 4);
    for (var i = 0; i < 128; i++) {
      fog[i * 4] = table[i * 2];
      fog[i * 4 + 1] = table[i * 2 + 1];
      fog[i * 4 + 3] = 255;
    }
    // The passes that used the old table have ended.
    _fog?.dispose();
    _fog = device.texture(128, 1, fog);
  }

  bool _sameFog(Uint8List table) {
    final last = _fogTable;
    for (var i = 0; i < 256; i++) {
      if (table[i] != last[i]) return false;
    }
    return true;
  }

  /// Draws [frame] into the top rows of [target], a target of the width of
  /// the frame and at least its height. [onComplete] is called when the GPU
  /// has finished.
  void draw(RenderFrame frame, GpuTarget target,
      {void Function(bool)? onComplete}) {
    prepare(frame);
    final clear = frame.clearColor;
    final pass = device.pass(target, _program, [frame.vertices, _cover],
        clearColor: [
          ((clear >> 16) & 255) / 255,
          ((clear >> 8) & 255) / 255,
          (clear & 255) / 255,
          ((clear >> 24) & 255) / 255
        ],
        clearDepth: (frame.clearDepth * frame.depthScale).clamp(0.0, 0.999));
    pass.uniform(
        'FrameInfo',
        ByteData.sublistView(Float32List.fromList([
          target.width.toDouble(),
          target.height.toDouble(),
          frame.depthScale,
          1e-7 / frame.depthScale
        ])));
    pass.texture('fog_table', _fog!);
    // Bit 7 of the stencil marks the pixels inside the volumes.
    pass.stencilReference(0x80);
    final stencil = device.stencil;
    final info = _fragmentInfo(frame);
    final stride = _fragmentStride;
    final batches = frame.batches;
    for (var i = 0; i < batches.length; i++) {
      final batch = batches[i];
      if (batch.pass == RenderBatch.volume) {
        if (!stencil) continue;
        pass.uniform('FragmentInfo', _noFog);
        pass.texture('texture_sampler', _white);
        _volume(pass, batch);
        continue;
      }
      final inside = batch.pass == RenderBatch.insideOpaque ||
          batch.pass == RenderBatch.insidePunchThrough;
      if (inside && !stencil) continue;
      pass.uniformAt('FragmentInfo', info, i * stride, _fragmentBytes);
      final texture = batch.texture;
      if (texture >= 0) {
        pass.texture('texture_sampler', _textures[texture], _samplers[texture]);
      } else {
        pass.texture('texture_sampler', _white);
      }
      pass.state(_states[(batch.state & 0x3ff) << 3 | batch.pass] ??=
          _batchState(batch));
      pass.draw(batch.first * 3, batch.count * 3);
    }
    pass.end(onComplete: onComplete);
  }

  // The bytes of the fragment uniforms of a batch, and their distance in
  // the list of a frame.
  static const _fragmentBytes = 16 * 4;
  final int _fragmentStride;

  /// The fragment uniforms of every batch of [frame], at the batch index
  /// times [_fragmentStride]. Volume batches have none.
  ByteData _fragmentInfo(RenderFrame frame) {
    final floats = _fragmentStride ~/ 4;
    final batches = frame.batches;
    final info = Float32List(batches.length * floats);
    final fogScale = frame.fogScale;
    final alphaReference = frame.alphaReference.toDouble();
    final fog = frame.fogColor, vertexFog = frame.vertexFogColor;
    for (var i = 0; i < batches.length; i++) {
      final batch = batches[i];
      if (batch.pass == RenderBatch.volume) continue;
      final o = i * floats;
      info[o] = batch.texture >= 0 ? 1 : 0;
      info[o + 1] = batch.shading.toDouble();
      info[o + 2] = batch.textureAlpha ? 1 : 0;
      info[o + 3] = batch.offset ? 1 : 0;
      info[o + 4] = batch.fog.toDouble();
      info[o + 5] = fogScale;
      info[o + 6] = batch.pass == RenderBatch.punchThrough ||
              batch.pass == RenderBatch.insidePunchThrough
          ? 1
          : 0;
      info[o + 7] = alphaReference;
      info[o + 8] = ((fog >> 16) & 255) / 255;
      info[o + 9] = ((fog >> 8) & 255) / 255;
      info[o + 10] = (fog & 255) / 255;
      info[o + 11] = 1;
      info[o + 12] = ((vertexFog >> 16) & 255) / 255;
      info[o + 13] = ((vertexFog >> 8) & 255) / 255;
      info[o + 14] = (vertexFog & 255) / 255;
      info[o + 15] = 1;
    }
    return ByteData.sublistView(info);
  }

  // The draw states of the batches by the bits of their state that select
  // it and their pass.
  final _states = <int, GpuState>{};

  static GpuState _batchState(RenderBatch batch) {
    final inside = batch.pass == RenderBatch.insideOpaque ||
        batch.pass == RenderBatch.insidePunchThrough;
    return GpuState(
        blend: batch.pass == RenderBatch.translucent,
        sourceFactor: _sourceFactors[batch.sourceFactor],
        destinationFactor: _destinationFactors[batch.destinationFactor],
        depthCompare: GpuCompare.values[batch.depthCompare],
        depthWrite: batch.depthWrite,
        stencilCompare: inside ? GpuCompare.equal : GpuCompare.always,
        stencilReadMask: 0x80,
        stencilWriteMask: 0);
  }

  // The fragment uniforms of volume steps, which draw no color.
  static final _noFog = ByteData.sublistView(Float32List(16)..[4] = 2);

  // A triangle over any frame, the second vertex array of a pass, for the
  // stencil steps of volumes. The vertex shader clips it to the frame.
  static final _cover = () {
    const floats = RenderFrame.vertexFloats;
    final cover = Float32List(3 * floats);
    for (final (i, (x, y)) in [(-1e4, -1e4), (3e4, -1e4), (-1e4, 3e4)].indexed) {
      cover[i * floats] = x;
      cover[i * floats + 1] = y;
      cover[i * floats + 2] = 1;
    }
    return cover;
  }();

  /// Draws a volume [batch] into the stencil bit of its layer, which then
  /// holds whether a pixel is inside one of its volumes. At the end of a
  /// group, the layers are folded into the inside area in bit 7 with the
  /// triangle over the frame, and cleared.
  static void _volume(GpuPass pass, RenderBatch batch) {
    // Volume steps keep the color: the source counts zero, the target one.
    pass.state(GpuState(
        blend: true,
        sourceFactor: GpuBlendFactor.zero,
        destinationFactor: GpuBlendFactor.one,
        depthCompare: GpuCompare.greaterEqual,
        stencilOperation: GpuStencilOperation.invert,
        stencilWriteMask: 1 << batch.volumeLayer));
    pass.draw(batch.first * 3, batch.count * 3);
    if (!batch.volumeGroupEnds) return;
    // Where a layer is set, inside last sets bit 7 and outside last clears
    // it. The masked reference is zero, so the compare tests for any layer.
    final union = batch.volumeInstruction == 1;
    pass.state(GpuState(
        blend: true,
        sourceFactor: GpuBlendFactor.zero,
        destinationFactor: GpuBlendFactor.one,
        stencilCompare: GpuCompare.notEqual,
        stencilOperation:
            union ? GpuStencilOperation.replace : GpuStencilOperation.zero,
        stencilReadMask: 0x7f,
        stencilWriteMask: 0x80));
    pass.draw(0, 3, 1);
    // The layers start again from zero for the next group.
    pass.state(GpuState(
        blend: true,
        sourceFactor: GpuBlendFactor.zero,
        destinationFactor: GpuBlendFactor.one,
        stencilOperation: GpuStencilOperation.zero,
        stencilWriteMask: 0x7f));
    pass.draw(0, 3, 1);
  }

  static GpuAddress _address(int mode) => switch (mode) {
        1 => GpuAddress.mirror,
        2 => GpuAddress.clamp,
        _ => GpuAddress.repeat,
      };

  static const _sourceFactors = [
    GpuBlendFactor.zero,
    GpuBlendFactor.one,
    GpuBlendFactor.destinationColor,
    GpuBlendFactor.oneMinusDestinationColor,
    GpuBlendFactor.sourceAlpha,
    GpuBlendFactor.oneMinusSourceAlpha,
    GpuBlendFactor.destinationAlpha,
    GpuBlendFactor.oneMinusDestinationAlpha,
  ];

  static const _destinationFactors = [
    GpuBlendFactor.zero,
    GpuBlendFactor.one,
    GpuBlendFactor.sourceColor,
    GpuBlendFactor.oneMinusSourceColor,
    GpuBlendFactor.sourceAlpha,
    GpuBlendFactor.oneMinusSourceAlpha,
    GpuBlendFactor.destinationAlpha,
    GpuBlendFactor.oneMinusDestinationAlpha,
  ];
}
