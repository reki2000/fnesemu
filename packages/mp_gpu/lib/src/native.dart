import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:vector_math/vector_math.dart' as vm;

import 'gpu.dart';

/// Flutter GPU, or null when the engine runs without it. The device checks
/// how long it has to wait before a read; see [_NativeDevice._calibrate].
Future<GpuDevice?> createDevice() async {
  final gpu.GpuContext context;
  try {
    context = gpu.gpuContext;
  } catch (_) {
    return null;
  }
  final device = _NativeDevice(context);
  await device._calibrate();
  return device;
}

/// A way to wait before reads: the frames of the engine to wait for after
/// the passes complete, and how often to read a target.
class _Sync {
  const _Sync(this.frames, this.reads);
  final int frames, reads;

  @override
  String toString() =>
      'completion${frames > 0 ? ' + $frames frame${frames > 1 ? 's' : ''}' : ''}'
      '${reads > 1 ? ', $reads reads' : ''}';
}

class _NativeDevice implements GpuDevice {
  _NativeDevice(this._context) : _host = _context.createHostBuffer();

  final gpu.GpuContext _context;

  // The uniforms of the draws. It cycles through four blocks, one for each
  // call of [settle], so the data of a draw stays in place until the GPU
  // has run it.
  final gpu.HostBuffer _host;

  // The ways to wait, from the shortest. The GLES backend may show a target
  // as it was before even after the passes complete: on some drivers until
  // a frame of the engine, and a read may need a second read. Vulkan and
  // Metal show it at once.
  static const _syncs = [_Sync(0, 1), _Sync(0, 2), _Sync(1, 2), _Sync(2, 2)];
  _Sync _sync = _syncs.last;

  // The completions of the passes ended since the last [settle].
  final _pending = <Future<void>>[];

  @override
  String get name => 'Flutter GPU';

  @override
  String get readBack => '$_sync';

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

  /// Waits for the passes to complete and then for the frames of the engine
  /// that the check chose, and starts a new block of uniforms. A completion
  /// that does not come within a second is not waited for any longer.
  @override
  Future<void> settle() async {
    final pending = [..._pending];
    _pending.clear();
    await Future.wait(
      pending,
    ).timeout(const Duration(seconds: 1), onTimeout: () => const []);
    for (var i = 0; i < _sync.frames; i++) {
      await SchedulerBinding.instance.endOfFrame;
    }
    _host.reset();
  }

  /// Reads the target as often as the check chose and returns the last.
  @override
  Future<Uint8List?> read(GpuTarget target) async {
    final color = (target as _NativeTarget).color;
    ByteData? data;
    for (var i = 0; i < _sync.reads; i++) {
      final image = color.asImage();
      try {
        data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      } finally {
        image.dispose();
      }
    }
    return data == null ? null : Uint8List.sublistView(data);
  }

  /// Chooses the shortest way to wait in [_syncs] that reads every check
  /// right. A check draws numbered frames into two targets, with large
  /// texture uploads as in a busy frame, and reads them back. A way fails at
  /// its first wrong read; the check takes at most two seconds in all, and then
  /// keeps the longest way. It also keeps the longest way when the shaders
  /// of the check do not load.
  Future<void> _calibrate() async {
    final watch = Stopwatch()..start();
    try {
      final check = await _Check.create(this);
      for (final sync in _syncs) {
        _sync = sync;
        if (await check.passes(watch)) return;
      }
    } catch (_) {
      // The longest way is kept.
    }
    _sync = _syncs.last;
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
  void end({void Function(bool success)? onComplete}) {
    final done = Completer<void>();
    _device._pending.add(done.future);
    _commands.submit(
      completionCallback: (success) {
        done.complete();
        onComplete?.call(success);
      },
    );
  }

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

/// Draws numbered frames and reads them back for [_NativeDevice._calibrate].
class _Check {
  _Check._(this._device, this._program, this._targets);

  static const _source = GpuProgramSource(
    bundle: 'packages/mp_gpu/shaders/check.shaderbundle',
    vertexEntry: 'CheckVertex',
    fragmentEntry: 'CheckFragment',
    wgsl: '',
    attributes: [2, 2],
    bindings: [GpuBinding.uniform('Info', 0), GpuBinding.texture('image', 1)],
  );

  static const _size = 16;
  static const _rounds = 10;
  static const _uploads = 4;
  static const _budget = Duration(seconds: 2);

  static Future<_Check> create(_NativeDevice device) async => _Check._(
    device,
    await device.program(_source),
    [for (var i = 0; i < 2; i++) device.target(_size, _size)],
  );

  final _NativeDevice _device;
  final GpuProgram _program;
  final List<GpuTarget> _targets;
  int _frame = 0;

  // A triangle over the whole target, and a tiny one in a corner for the
  // large textures, with x and y in clip space and u and v.
  static final _vertices = Float32List.fromList([
    -1, -1, 0, 0, 3, -1, 0, 0, -1, 3, 0, 0, //
    -1, 1, 0, 0, -0.99, 1, 0, 0, -1, 0.99, 0, 0,
  ]);
  static final _white = ByteData.sublistView(
    Float32List.fromList([1, 1, 1, 1]),
  );
  static final _large = Uint8List(256 * 256 * 4);

  /// Whether every read of [_rounds] rounds is right with the current way to
  /// wait. A check past the budget of [watch] does not pass.
  Future<bool> passes(Stopwatch watch) async {
    for (var round = 0; round < _rounds; round++) {
      if (watch.elapsed > _budget) return false;
      final frames = [for (final t in _targets) _draw(t)];
      await _device.settle();
      for (final (i, t) in _targets.indexed) {
        final rgba = await _device.read(t);
        if (rgba == null) return false;
        final center = (_size ~/ 2 * _size + _size ~/ 2) * 4;
        if (rgba[center] != frames[i] & 0xff ||
            rgba[center + 1] != frames[i] >> 8 & 0xff) {
          return false;
        }
      }
    }
    return watch.elapsed <= _budget;
  }

  // Draws the next frame into [target]: red and green of the whole target
  // hold its number. Returns the number.
  int _draw(GpuTarget target) {
    final n = ++_frame;
    final texture = _device.texture(
      1,
      1,
      Uint8List.fromList([n & 0xff, n >> 8 & 0xff, 0x5a, 255]),
    );
    final pass = _device.pass(
      target,
      _program,
      [_vertices],
      clearColor: const [0.5, 0.5, 0.5, 1],
      clearDepth: 1,
    );
    pass.uniform('Info', _white);
    for (var j = 0; j < _uploads; j++) {
      pass.texture(
        'image',
        _device.texture(256, 256, _large..fillRange(0, 4, n + j & 0xff)),
      );
      pass.draw(3, 3);
    }
    pass.texture('image', texture);
    pass.draw(0, 3);
    pass.end();
    return n;
  }
}
