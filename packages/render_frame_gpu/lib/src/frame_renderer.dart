import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:fnesemu_core/app_api.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// Draws [RenderFrame]s with Flutter GPU into an offscreen color texture.
///
/// This is a first, plain implementation: every frame uploads its vertices
/// and its textures and draws each batch with its own state.
class FrameRenderer {
  FrameRenderer._(this._vertex, this._fragment, this._pipeline);

  static const _bundle = 'packages/render_frame_gpu/shaders/frame.shaderbundle';

  static Future<FrameRenderer> create() async {
    final library = await gpu.ShaderLibrary.fromAsset(_bundle);
    if (library == null) throw StateError('cannot load $_bundle');
    final vertex = library['FrameVertex']!,
        fragment = library['FrameFragment']!;
    return FrameRenderer._(vertex, fragment,
        gpu.gpuContext.createRenderPipeline(vertex, fragment));
  }

  final gpu.Shader _vertex, _fragment;
  final gpu.RenderPipeline _pipeline;
  final _host = gpu.gpuContext.createHostBuffer();
  gpu.Texture? _color, _depth;
  late final gpu.Texture _white =
      _texture(1, 1, Uint8List.fromList([255, 255, 255, 255]));

  RenderFrame? _prepared;
  List<gpu.Texture> _textures = const [];
  gpu.Texture? _fog;

  /// Uploads the textures and the fog table of [frame].
  ///
  /// On the GLES backend, textures that were uploaded once lost their
  /// contents after some tens of frames, so the textures of a frame drawn
  /// again are written again.
  void prepare(RenderFrame frame) {
    if (identical(frame, _prepared)) {
      for (var i = 0; i < _textures.length; i++) {
        _textures[i].overwrite(ByteData.sublistView(frame.textures[i].rgba));
      }
      return;
    }
    _textures = [
      for (final t in frame.textures) _texture(t.width, t.height, t.rgba)
    ];
    final fog = Uint8List(128 * 4);
    for (var i = 0; i < 128; i++) {
      fog[i * 4] = frame.fogTable[i * 2];
      fog[i * 4 + 1] = frame.fogTable[i * 2 + 1];
      fog[i * 4 + 3] = 255;
    }
    _fog = _texture(128, 1, fog);
    _prepared = frame;
  }

  gpu.Texture _texture(int width, int height, Uint8List rgba) {
    final texture = gpu.gpuContext.createTexture(
        gpu.StorageMode.hostVisible, width, height,
        enableRenderTargetUsage: false);
    texture.overwrite(ByteData.sublistView(rgba));
    return texture;
  }

  /// Draws [frame] and returns its color texture. [onComplete] is called
  /// when the GPU has finished.
  gpu.Texture draw(RenderFrame frame, {void Function(bool)? onComplete}) {
    prepare(frame);
    final context = gpu.gpuContext;
    var color = _color, depth = _depth;
    if (color == null ||
        color.width != frame.width ||
        color.height != frame.height) {
      color = _color = context.createTexture(
          gpu.StorageMode.devicePrivate, frame.width, frame.height,
          format: context.defaultColorFormat);
      depth = _depth = context.createTexture(
          gpu.StorageMode.deviceTransient, frame.width, frame.height,
          format: context.defaultDepthStencilFormat,
          enableShaderReadUsage: false);
    }
    _host.reset();
    final vertices = context
        .createDeviceBufferWithCopy(ByteData.sublistView(frame.vertices));
    final commands = context.createCommandBuffer();
    final clear = frame.clearColor;
    final pass = commands.createRenderPass(gpu.RenderTarget(
      colorAttachments: [
        gpu.ColorAttachment(
            texture: color,
            clearValue: vm.Vector4(
                ((clear >> 16) & 255) / 255,
                ((clear >> 8) & 255) / 255,
                (clear & 255) / 255,
                ((clear >> 24) & 255) / 255)),
      ],
      depthStencilAttachment: gpu.DepthStencilAttachment(
          texture: depth!,
          depthClearValue:
              (frame.clearDepth * frame.depthScale).clamp(0.0, 0.999)),
    ));
    final frameInfo = _host.emplace(ByteData.sublistView(Float32List.fromList([
      frame.width.toDouble(),
      frame.height.toDouble(),
      frame.depthScale,
      1e-7 / frame.depthScale
    ])));
    final fogColor = _color4(frame.fogColor),
        vertexFogColor = _color4(frame.vertexFogColor);
    final frameSlot = _vertex.getUniformSlot('FrameInfo');
    final fragmentSlot = _fragment.getUniformSlot('FragmentInfo');
    final textureSlot = _fragment.getUniformSlot('texture_sampler');
    final fogSlot = _fragment.getUniformSlot('fog_table');
    final fogSampler = gpu.SamplerOptions();
    const vertexBytes = RenderFrame.vertexFloats * 4 * 3;
    for (final batch in frame.batches) {
      pass.bindPipeline(_pipeline);
      pass.setCullMode(gpu.CullMode.none);
      pass.bindVertexBuffer(gpu.BufferView(vertices,
          offsetInBytes: batch.first * vertexBytes,
          lengthInBytes: batch.count * vertexBytes));
      pass.bindUniform(frameSlot, frameInfo);
      final textured = batch.texture >= 0;
      pass.bindUniform(
          fragmentSlot,
          _host.emplace(ByteData.sublistView(Float32List.fromList([
            textured ? 1 : 0,
            batch.shading.toDouble(),
            batch.textureAlpha ? 1 : 0,
            batch.offset ? 1 : 0,
            batch.fog.toDouble(),
            frame.fogScale,
            batch.pass == RenderBatch.punchThrough ? 1 : 0,
            frame.alphaReference.toDouble(),
            ...fogColor,
            ...vertexFogColor,
          ]))));
      if (textured) {
        final t = frame.textures[batch.texture];
        pass.bindTexture(textureSlot, _textures[batch.texture],
            sampler: gpu.SamplerOptions(
                minFilter: t.bilinear
                    ? gpu.MinMagFilter.linear
                    : gpu.MinMagFilter.nearest,
                magFilter: t.bilinear
                    ? gpu.MinMagFilter.linear
                    : gpu.MinMagFilter.nearest,
                widthAddressMode: _address(t.addressU),
                heightAddressMode: _address(t.addressV)));
      } else {
        pass.bindTexture(textureSlot, _white);
      }
      pass.bindTexture(fogSlot, _fog!, sampler: fogSampler);
      pass.setDepthWriteEnable(batch.depthWrite);
      pass.setDepthCompareOperation(_compare[batch.depthCompare]);
      final blend = batch.pass == RenderBatch.translucent;
      pass.setColorBlendEnable(blend);
      if (blend) {
        final source = _sourceFactors[batch.sourceFactor];
        final destination = _destinationFactors[batch.destinationFactor];
        pass.setColorBlendEquation(gpu.ColorBlendEquation(
            sourceColorBlendFactor: source,
            destinationColorBlendFactor: destination,
            sourceAlphaBlendFactor: source,
            destinationAlphaBlendFactor: destination));
      }
      pass.draw(batch.count * 3);
    }
    commands.submit(completionCallback: onComplete);
    return color;
  }

  static List<double> _color4(int rgb) => [
        ((rgb >> 16) & 255) / 255,
        ((rgb >> 8) & 255) / 255,
        (rgb & 255) / 255,
        1
      ];

  static gpu.SamplerAddressMode _address(int mode) => switch (mode) {
        1 => gpu.SamplerAddressMode.mirror,
        2 => gpu.SamplerAddressMode.clampToEdge,
        _ => gpu.SamplerAddressMode.repeat,
      };

  static const _compare = [
    gpu.CompareFunction.never,
    gpu.CompareFunction.less,
    gpu.CompareFunction.equal,
    gpu.CompareFunction.lessEqual,
    gpu.CompareFunction.greater,
    gpu.CompareFunction.notEqual,
    gpu.CompareFunction.greaterEqual,
    gpu.CompareFunction.always,
  ];

  static const _sourceFactors = [
    gpu.BlendFactor.zero,
    gpu.BlendFactor.one,
    gpu.BlendFactor.destinationColor,
    gpu.BlendFactor.oneMinusDestinationColor,
    gpu.BlendFactor.sourceAlpha,
    gpu.BlendFactor.oneMinusSourceAlpha,
    gpu.BlendFactor.destinationAlpha,
    gpu.BlendFactor.oneMinusDestinationAlpha,
  ];

  static const _destinationFactors = [
    gpu.BlendFactor.zero,
    gpu.BlendFactor.one,
    gpu.BlendFactor.sourceColor,
    gpu.BlendFactor.oneMinusSourceColor,
    gpu.BlendFactor.sourceAlpha,
    gpu.BlendFactor.oneMinusSourceAlpha,
    gpu.BlendFactor.destinationAlpha,
    gpu.BlendFactor.oneMinusDestinationAlpha,
  ];
}
