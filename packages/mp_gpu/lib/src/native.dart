import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:vector_math/vector_math.dart' as vm;

import 'gpu.dart';

/// Flutter GPU, or null when the engine runs without it.
Future<GpuDevice?> createDevice() async {
  try {
    return _NativeDevice(gpu.gpuContext);
  } catch (_) {
    return null;
  }
}

class _NativeDevice implements GpuDevice {
  _NativeDevice(this._context) : _host = _context.createHostBuffer();

  final gpu.GpuContext _context;

  // The uniforms of the draws. It cycles through four blocks, one for each
  // call of [settle], so the data of a draw stays in place until the GPU
  // has run it.
  final gpu.HostBuffer _host;

  @override
  String get name => 'Flutter GPU';

  @override
  bool get stencil => switch (_context.defaultDepthStencilFormat) {
    gpu.PixelFormat.d24UnormS8Uint || gpu.PixelFormat.d32FloatS8UInt => true,
    _ => false,
  };

  @override
  Future<GpuProgram> program(GpuProgramSource source) async {
    final library = await gpu.ShaderLibrary.fromAsset(source.bundle);
    final vertex = library?[source.vertexEntry];
    final fragment = library?[source.fragmentEntry];
    if (vertex == null || fragment == null) {
      throw StateError('cannot load ${source.bundle}');
    }
    final bindings = source.bindings;
    return _NativeProgram(
      _context.createRenderPipeline(vertex, fragment),
      {for (final (i, b) in bindings.indexed) b.name: i},
      [
        for (final b in bindings)
          (b.vertex ? vertex : fragment).getUniformSlot(b.name),
      ],
      source.attributes.fold(0, (n, floats) => n + floats * 4),
    );
  }

  @override
  GpuTexture texture(int width, int height, Uint8List rgba) {
    final texture = _context.createTexture(
      gpu.StorageMode.hostVisible,
      width,
      height,
      enableRenderTargetUsage: false,
    );
    texture.overwrite(ByteData.sublistView(rgba));
    return _NativeTexture(texture);
  }

  @override
  GpuTarget target(int width, int height) => _NativeTarget(
    _context.createTexture(
      gpu.StorageMode.devicePrivate,
      width,
      height,
      format: _context.defaultColorFormat,
    ),
    _context.createTexture(
      gpu.StorageMode.deviceTransient,
      width,
      height,
      format: _context.defaultDepthStencilFormat,
      enableShaderReadUsage: false,
    ),
  );

  @override
  GpuPass pass(
    GpuTarget target,
    GpuProgram program,
    List<Float32List> vertices, {
    required List<double> clearColor,
    required double clearDepth,
  }) {
    target as _NativeTarget;
    final commands = _context.createCommandBuffer();
    final pass = commands.createRenderPass(
      gpu.RenderTarget(
        colorAttachments: [
          gpu.ColorAttachment(
            texture: target.color,
            clearValue: vm.Vector4(
              clearColor[0],
              clearColor[1],
              clearColor[2],
              clearColor[3],
            ),
          ),
        ],
        depthStencilAttachment: gpu.DepthStencilAttachment(
          texture: target.depth,
          depthClearValue: clearDepth,
        ),
      ),
    );
    return _NativePass(this, program as _NativeProgram, commands, pass, [
      for (final v in vertices)
        _context.createDeviceBufferWithCopy(ByteData.sublistView(v)),
    ]);
  }

  /// Waits for a frame of the engine, after which the GLES backend has run
  /// the passes, and starts a new block of uniforms.
  @override
  Future<void> settle() async {
    await SchedulerBinding.instance.endOfFrame;
    _host.reset();
  }

  /// On the GLES backend, a read often showed the texture as it was at the
  /// read before. The pixels are read twice; that was right for all but
  /// about one frame in a few hundred, which then shows the frame before.
  @override
  Future<Uint8List?> read(GpuTarget target) async {
    final color = (target as _NativeTarget).color;
    Future<ByteData?> once() async {
      final image = color.asImage();
      try {
        return await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      } finally {
        image.dispose();
      }
    }

    await once();
    final data = await once();
    return data == null ? null : Uint8List.sublistView(data);
  }
}

class _NativeProgram implements GpuProgram {
  _NativeProgram(this.pipeline, this.indices, this.slots, this.vertexBytes);
  final gpu.RenderPipeline pipeline;
  // The index of each binding by name, and its slot.
  final Map<String, int> indices;
  final List<gpu.UniformSlot> slots;
  final int vertexBytes;
}

class _NativeTexture implements GpuTexture {
  _NativeTexture(this.texture);
  final gpu.Texture texture;
  @override
  int get width => texture.width;
  @override
  int get height => texture.height;
}

class _NativeTarget implements GpuTarget {
  _NativeTarget(this.color, this.depth);
  final gpu.Texture color, depth;
  @override
  int get width => color.width;
  @override
  int get height => color.height;
}

class _NativePass implements GpuPass {
  _NativePass(
    this._device,
    this._program,
    this._commands,
    this._pass,
    this._vertices,
  ) : _uniforms = List.filled(_program.slots.length, null),
      _textures = List.filled(_program.slots.length, null),
      _samplers = List.filled(_program.slots.length, null);

  final _NativeDevice _device;
  final _NativeProgram _program;
  final gpu.CommandBuffer _commands;
  final gpu.RenderPass _pass;
  final List<gpu.DeviceBuffer> _vertices;
  // The bindings by index. They and the state are set again before each
  // draw: the backend may not keep them over a change of the vertex buffer.
  final List<gpu.BufferView?> _uniforms;
  final List<gpu.Texture?> _textures;
  final List<gpu.SamplerOptions?> _samplers;
  GpuState _state = const GpuState();
  int _reference = 0;

  @override
  void uniform(String name, ByteData data) =>
      _uniforms[_program.indices[name]!] = _device._host.emplace(data);

  @override
  void texture(
    String name,
    GpuTexture texture, [
    GpuSampler sampler = const GpuSampler(),
  ]) {
    final index = _program.indices[name]!;
    _textures[index] = (texture as _NativeTexture).texture;
    _samplers[index] = _samplerOptions[sampler.key] ??= gpu.SamplerOptions(
      minFilter: sampler.linear
          ? gpu.MinMagFilter.linear
          : gpu.MinMagFilter.nearest,
      magFilter: sampler.linear
          ? gpu.MinMagFilter.linear
          : gpu.MinMagFilter.nearest,
      widthAddressMode: _address[sampler.addressU.index],
      heightAddressMode: _address[sampler.addressV.index],
    );
  }

  static final _samplerOptions = <int, gpu.SamplerOptions>{};

  @override
  void state(GpuState state) => _state = state;

  @override
  void stencilReference(int value) => _reference = value;

  @override
  void draw(int first, int count, [int array = 0]) {
    final pass = _pass, state = _state, bytes = _program.vertexBytes;
    final slots = _program.slots;
    pass.bindPipeline(_program.pipeline);
    pass.setCullMode(gpu.CullMode.none);
    pass.bindVertexBuffer(
      gpu.BufferView(
        _vertices[array],
        offsetInBytes: first * bytes,
        lengthInBytes: count * bytes,
      ),
    );
    for (var i = 0; i < slots.length; i++) {
      final uniform = _uniforms[i];
      if (uniform != null) {
        pass.bindUniform(slots[i], uniform);
      } else {
        final texture = _textures[i];
        if (texture != null) {
          pass.bindTexture(slots[i], texture, sampler: _samplers[i]);
        }
      }
    }
    pass.setColorBlendEnable(state.blend);
    if (state.blend) {
      final source = _factors[state.sourceFactor.index];
      final destination = _factors[state.destinationFactor.index];
      pass.setColorBlendEquation(
        gpu.ColorBlendEquation(
          sourceColorBlendFactor: source,
          destinationColorBlendFactor: destination,
          sourceAlphaBlendFactor: source,
          destinationAlphaBlendFactor: destination,
        ),
      );
    }
    pass.setDepthWriteEnable(state.depthWrite);
    pass.setDepthCompareOperation(_compare[state.depthCompare.index]);
    pass.setStencilReference(_reference);
    pass.setStencilConfig(
      gpu.StencilConfig(
        compareFunction: _compare[state.stencilCompare.index],
        depthStencilPassOperation: _operations[state.stencilOperation.index],
        readMask: state.stencilReadMask,
        writeMask: state.stencilWriteMask,
      ),
    );
    pass.draw(count);
  }

  @override
  void end({void Function(bool success)? onComplete}) =>
      _commands.submit(completionCallback: onComplete);

  static const _address = [
    gpu.SamplerAddressMode.repeat,
    gpu.SamplerAddressMode.mirror,
    gpu.SamplerAddressMode.clampToEdge,
  ];

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

  static const _factors = [
    gpu.BlendFactor.zero,
    gpu.BlendFactor.one,
    gpu.BlendFactor.sourceColor,
    gpu.BlendFactor.oneMinusSourceColor,
    gpu.BlendFactor.sourceAlpha,
    gpu.BlendFactor.oneMinusSourceAlpha,
    gpu.BlendFactor.destinationColor,
    gpu.BlendFactor.oneMinusDestinationColor,
    gpu.BlendFactor.destinationAlpha,
    gpu.BlendFactor.oneMinusDestinationAlpha,
  ];

  static const _operations = [
    gpu.StencilOperation.keep,
    gpu.StencilOperation.zero,
    gpu.StencilOperation.setToReferenceValue,
    gpu.StencilOperation.invert,
  ];
}
