import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:vector_math/vector_math.dart' as vm;

import 'gpu.dart';
import 'stamp.dart';

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
  try {
    device._stampProgram =
        await device.program(checkSource) as _NativeProgram;
  } catch (_) {
    // Without the program, passes draw no stamps and the check cannot run.
  }
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

class _NativeDevice implements GpuDevice, GpuStamping {
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
  _Sync _sync = _syncs.first;

  // The completions of the passes ended since the last [settle].
  final _pending = <Future<void>>[];

  // The program of the check and the stamps, a white texture for it, and
  // the vertices of the last row of a target by its height.
  _NativeProgram? _stampProgram;
  late final gpu.Texture _white = (texture(
    1,
    1,
    Uint8List.fromList([255, 255, 255, 255]),
  ) as _NativeTexture).texture;
  final _stampRows = <int, gpu.DeviceBuffer>{};

  @override
  bool get stamps => _stampProgram != null;

  @override
  late final int uniformAlignment = _context.minimumUniformByteAlignment;

  @override
  void stampOnly(GpuTarget target) => pass(
    target,
    _stampProgram!,
    const [],
    clearColor: const [0, 0, 0, 0],
    clearDepth: 0,
  ).end();

  /// A rectangle over the last row of a target of [height], with x and y
  /// in clip space and u and v.
  gpu.DeviceBuffer _stampRow(int height) =>
      _stampRows[height] ??= _context.createDeviceBufferWithCopy(() {
        final top = -1 + 2 / height;
        return ByteData.sublistView(
          Float32List.fromList([
            -1, -1, 0, 0, 1, -1, 0, 0, -1, top, 0, 0, //
            -1, top, 0, 0, 1, -1, 0, 0, 1, top, 0, 0,
          ]),
        );
      }());

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
    required List<double>? clearColor,
    required double clearDepth,
    List<Uint32List> indices = const [],
  }) {
    target as _NativeTarget;
    final commands = _context.createCommandBuffer();
    final pass = commands.createRenderPass(
      gpu.RenderTarget(
        colorAttachments: [
          gpu.ColorAttachment(
            texture: target.color,
            loadAction: clearColor == null
                ? gpu.LoadAction.load
                : gpu.LoadAction.clear,
            clearValue: clearColor == null
                ? null
                : vm.Vector4(
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
    return _NativePass(
      this,
      target,
      program as _NativeProgram,
      commands,
      pass,
      [
        for (final v in vertices)
          _context.createDeviceBufferWithCopy(ByteData.sublistView(v)),
      ],
      [
        for (final i in indices)
          _context.createDeviceBufferWithCopy(ByteData.sublistView(i)),
      ],
    );
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
  /// its first wrong read, and the longest way is kept when all fail. When
  /// the check cannot tell, because its shaders do not load or its budget
  /// of two seconds runs out, as while the app is hidden, the first way,
  /// the completion alone, is used.
  Future<void> _calibrate() async {
    final watch = Stopwatch()..start();
    try {
      final check = _Check.create(this);
      for (final sync in _syncs) {
        _sync = sync;
        switch (await check.passes(watch)) {
          case true:
            return;
          case null:
            _sync = _syncs.first;
            return;
          case false:
          // A wrong read: the next way is tried.
        }
      }
      _sync = _syncs.last;
    } catch (_) {
      _sync = _syncs.first;
    }
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
  @override
  void overwrite(Uint8List rgba) =>
      texture.overwrite(ByteData.sublistView(rgba));
  @override
  void dispose() {}
}

class _NativeTarget implements GpuTarget {
  _NativeTarget(this.color, this.depth);
  final gpu.Texture color, depth;
  @override
  GpuTexture get colorTexture => _NativeTexture(color);
  @override
  int get width => color.width;
  @override
  int get height => color.height;
}

class _NativePass implements GpuPass {
  _NativePass(
    this._device,
    this._target,
    this._program,
    this._commands,
    this._pass,
    this._vertices,
    this._indices,
  ) : _uniforms = List.filled(_program.slots.length, null),
      _textures = List.filled(_program.slots.length, null),
      _samplers = List.filled(_program.slots.length, null),
      _boundUniforms = List.filled(_program.slots.length, null),
      _boundTextures = List.filled(_program.slots.length, null),
      _boundSamplers = List.filled(_program.slots.length, null);

  final _NativeDevice _device;
  final _NativeTarget _target;
  final _NativeProgram _program;
  final gpu.CommandBuffer _commands;
  final gpu.RenderPass _pass;
  final List<gpu.DeviceBuffer> _vertices, _indices;
  // The bindings of the next draw by index.
  final List<gpu.BufferView?> _uniforms;
  final List<gpu.Texture?> _textures;
  final List<gpu.SamplerOptions?> _samplers;
  // What the render pass holds. It keeps its bindings and state from draw
  // to draw, so a draw sets only what differs from the draw before.
  final List<gpu.BufferView?> _boundUniforms;
  final List<gpu.Texture?> _boundTextures;
  final List<gpu.SamplerOptions?> _boundSamplers;
  bool _pipelineBound = false;
  int _boundState = -1, _boundReference = -1;
  // The scissor of the next draws and of the render pass, as x, y, width
  // and height; a width of -1 means none.
  final _scissor = Int32List(4)..[2] = -1;
  final _boundScissor = Int32List(4)..[2] = -1;
  GpuState _state = const GpuState();
  int _reference = 0;

  // The last list of [uniformAt] and the buffer it was uploaded to.
  ByteData? _shared;
  gpu.DeviceBuffer? _sharedBuffer;

  @override
  void uniform(String name, ByteData data) =>
      _uniforms[_program.indices[name]!] = _device._host.emplace(data);

  @override
  void uniformAt(String name, ByteData data, int offset, int length) {
    // A buffer of its own: the host buffer fails to place a list that does
    // not fit into the rest of its block.
    var buffer = _sharedBuffer;
    if (buffer == null || !identical(data, _shared)) {
      buffer = _sharedBuffer = _device._context.createDeviceBufferWithCopy(
        data,
      );
      _shared = data;
    }
    _uniforms[_program.indices[name]!] = gpu.BufferView(
      buffer,
      offsetInBytes: offset,
      lengthInBytes: length,
    );
  }

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
  @override
  void scissor(int x, int y, int width, int height) => _scissor
    ..[0] = x
    ..[1] = y
    ..[2] = width
    ..[3] = height;

  @override
  void draw(int first, int count, [int array = 0]) {
    final bytes = _program.vertexBytes;
    _pass.bindVertexBuffer(
      gpu.BufferView(
        _vertices[array],
        offsetInBytes: first * bytes,
        lengthInBytes: count * bytes,
      ),
    );
    _bind();
    _pass.draw(count);
  }

  @override
  void drawIndexed(int first, int count, [int array = 0, int indexArray = 0]) {
    final vertices = _vertices[array];
    _pass.bindVertexBuffer(
      gpu.BufferView(
        vertices,
        offsetInBytes: 0,
        lengthInBytes: vertices.sizeInBytes,
      ),
    );
    _pass.bindIndexBuffer(
      gpu.BufferView(
        _indices[indexArray],
        offsetInBytes: first * 4,
        lengthInBytes: count * 4,
      ),
      gpu.IndexType.int32,
    );
    _bind();
    _pass.drawIndexed(count);
  }

  /// Sets the bindings and the state of the next draw that differ from the
  /// render pass.
  void _bind() {
    final pass = _pass, state = _state;
    final slots = _program.slots;
    if (!_pipelineBound) {
      pass.bindPipeline(_program.pipeline);
      pass.setWindingOrder(gpu.WindingOrder.counterClockwise);
      _pipelineBound = true;
    }
    for (var i = 0; i < slots.length; i++) {
      final uniform = _uniforms[i];
      if (uniform != null) {
        final bound = _boundUniforms[i];
        if (bound == null ||
            !identical(bound.buffer, uniform.buffer) ||
            bound.offsetInBytes != uniform.offsetInBytes ||
            bound.lengthInBytes != uniform.lengthInBytes) {
          pass.bindUniform(slots[i], uniform);
          _boundUniforms[i] = uniform;
        }
      } else {
        final texture = _textures[i];
        final sampler = _samplers[i];
        if (texture != null &&
            (!identical(texture, _boundTextures[i]) ||
                !identical(sampler, _boundSamplers[i]))) {
          pass.bindTexture(slots[i], texture, sampler: sampler);
          _boundTextures[i] = texture;
          _boundSamplers[i] = sampler;
        }
      }
    }
    final key = state.key;
    if (key != _boundState) {
      _setState(state);
      _boundState = key;
    }
    if (_reference != _boundReference) {
      pass.setStencilReference(_reference);
      _boundReference = _reference;
    }
    final scissor = _scissor, bound = _boundScissor;
    if (scissor[0] != bound[0] ||
        scissor[1] != bound[1] ||
        scissor[2] != bound[2] ||
        scissor[3] != bound[3]) {
      _setScissor(scissor);
      bound.setAll(0, scissor);
    }
  }

  /// Sets the scissor of the render pass to [scissor], or to the whole
  /// target when its width is -1.
  void _setScissor(Int32List scissor) {
    final none = scissor[2] < 0;
    _pass.setScissor(
      gpu.Scissor(
        x: none ? 0 : scissor[0],
        y: none ? 0 : scissor[1],
        width: none ? _target.width : scissor[2],
        height: none ? _target.height : scissor[3],
      ),
    );
  }

  void _setState(GpuState state) {
    final pass = _pass;
    pass.setCullMode(_culls[state.cull.index]);
    pass.setColorBlendEnable(state.blend);
    if (state.blend) {
      pass.setColorBlendEquation(
        gpu.ColorBlendEquation(
          colorBlendOperation: _operationsOfBlend[state.operation.index],
          sourceColorBlendFactor: _factors[state.sourceFactor.index],
          destinationColorBlendFactor: _factors[state.destinationFactor.index],
          alphaBlendOperation: _operationsOfBlend[state.alphaBlend.index],
          sourceAlphaBlendFactor: _factors[state.alphaSource.index],
          destinationAlphaBlendFactor: _factors[state.alphaDestination.index],
        ),
      );
    }
    pass.setDepthWriteEnable(state.depthWrite);
    pass.setDepthCompareOperation(_compare[state.depthCompare.index]);
    pass.setStencilConfig(
      gpu.StencilConfig(
        compareFunction: _compare[state.stencilCompare.index],
        depthStencilPassOperation: _operations[state.stencilOperation.index],
        readMask: state.stencilReadMask,
        writeMask: state.stencilWriteMask,
      ),
    );
  }

  @override
  void end({void Function(bool success)? onComplete}) {
    _drawStamp();
    final done = Completer<void>();
    _device._pending.add(done.future);
    _commands.submit(
      completionCallback: (success) {
        done.complete();
        onComplete?.call(success);
      },
    );
  }

  /// Draws the stamp of the target, if it has one, into its last row: the
  /// number in red, green and blue from the least significant byte.
  void _drawStamp() {
    final stamp = targetStamps[_target];
    final program = _device._stampProgram;
    if (stamp == null || program == null) return;
    final pass = _pass;
    // The bindings of the draws before stay in the render pass, and one of
    // the same name as a binding of the stamp would be used instead.
    pass.clearBindings();
    pass.bindPipeline(program.pipeline);
    pass.setCullMode(gpu.CullMode.none);
    pass.bindVertexBuffer(
      gpu.BufferView(
        _device._stampRow(_target.height),
        offsetInBytes: 0,
        lengthInBytes: 6 * program.vertexBytes,
      ),
    );
    pass.bindUniform(
      program.slots[0],
      _device._host.emplace(
        ByteData.sublistView(
          Float32List.fromList([
            (stamp & 0xff) / 255,
            (stamp >> 8 & 0xff) / 255,
            (stamp >> 16 & 0xff) / 255,
            1,
          ]),
        ),
      ),
    );
    pass.bindTexture(
      program.slots[1],
      _device._white,
      sampler: gpu.SamplerOptions(),
    );
    pass.setScissor(
      gpu.Scissor(width: _target.width, height: _target.height),
    );
    pass.setColorBlendEnable(false);
    pass.setDepthWriteEnable(false);
    pass.setDepthCompareOperation(gpu.CompareFunction.always);
    pass.setStencilReference(0);
    pass.setStencilConfig(
      gpu.StencilConfig(
        compareFunction: gpu.CompareFunction.always,
        depthStencilPassOperation: gpu.StencilOperation.keep,
      ),
    );
    pass.draw(6);
  }

  static const _culls = [
    gpu.CullMode.none,
    gpu.CullMode.frontFace,
    gpu.CullMode.backFace,
  ];

  static const _operationsOfBlend = [
    gpu.BlendOperation.add,
    gpu.BlendOperation.subtract,
    gpu.BlendOperation.reverseSubtract,
  ];

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

  static const _size = 16;
  static const _rounds = 10;
  static const _uploads = 4;
  static const _budget = Duration(seconds: 2);

  static _Check create(_NativeDevice device) => _Check._(
    device,
    device._stampProgram ?? (throw StateError('no check program')),
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
  /// wait: false at the first wrong read, and null when the budget of
  /// [watch] runs out first or a target cannot be read.
  Future<bool?> passes(Stopwatch watch) async {
    for (var round = 0; round < _rounds; round++) {
      if (watch.elapsed > _budget) return null;
      final frames = [for (final t in _targets) _draw(t)];
      // The engine makes no frames while the app is hidden, so no wait may
      // run past the budget.
      Future<T> limit<T>(Future<T> f) => f.timeout(_budget - watch.elapsed);
      try {
        await limit(_device.settle());
      } on TimeoutException {
        return null;
      }
      for (final (i, t) in _targets.indexed) {
        final Uint8List? rgba;
        try {
          rgba = await limit(_device.read(t));
        } on TimeoutException {
          return null;
        }
        if (rgba == null) return null;
        final center = (_size ~/ 2 * _size + _size ~/ 2) * 4;
        if (rgba[center] != frames[i] & 0xff ||
            rgba[center + 1] != frames[i] >> 8 & 0xff) {
          return false;
        }
      }
    }
    return true;
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
