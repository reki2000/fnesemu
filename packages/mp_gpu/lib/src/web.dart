import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'gpu.dart';

/// WebGPU, or null when the browser has no adapter.
Future<GpuDevice?> createDevice() async {
  try {
    final gpu = _navigatorGpu;
    if (gpu == null) return null;
    final adapter = await gpu.requestAdapter().toDart;
    if (adapter == null) return null;
    return _WebDevice(await adapter.requestDevice().toDart);
  } catch (_) {
    return null;
  }
}

@JS('navigator.gpu')
external _Gpu? get _navigatorGpu;

extension type _Gpu._(JSObject _) implements JSObject {
  external JSPromise<_Adapter?> requestAdapter();
}

extension type _Adapter._(JSObject _) implements JSObject {
  external JSPromise<_Device> requestDevice();
}

extension type _Device._(JSObject _) implements JSObject {
  external _Queue get queue;
  external _Texture createTexture(JSObject descriptor);
  external _Buffer createBuffer(JSObject descriptor);
  external JSObject createSampler(JSObject descriptor);
  external JSObject createShaderModule(JSObject descriptor);
  external JSObject createBindGroupLayout(JSObject descriptor);
  external JSObject createPipelineLayout(JSObject descriptor);
  external JSObject createRenderPipeline(JSObject descriptor);
  external JSObject createBindGroup(JSObject descriptor);
  external _Encoder createCommandEncoder();
}

extension type _Queue._(JSObject _) implements JSObject {
  external void writeBuffer(_Buffer buffer, int offset, JSAny data);
  external void writeTexture(
    JSObject destination,
    JSAny data,
    JSObject layout,
    JSObject size,
  );
  external void submit(JSArray<JSObject> buffers);
  external JSPromise<JSAny?> onSubmittedWorkDone();
}

extension type _Encoder._(JSObject _) implements JSObject {
  external _RenderPass beginRenderPass(JSObject descriptor);
  external void copyTextureToBuffer(
    JSObject source,
    JSObject destination,
    JSObject size,
  );
  external JSObject finish();
}

extension type _RenderPass._(JSObject _) implements JSObject {
  external void setPipeline(JSObject pipeline);
  external void setBindGroup(
    int index,
    JSObject group,
    JSArray<JSNumber> dynamicOffsets,
  );
  external void setVertexBuffer(int slot, _Buffer buffer, int offset);
  external void setStencilReference(int reference);
  external void draw(int vertexCount, int instanceCount, int firstVertex);
  external void end();
}

extension type _Buffer._(JSObject _) implements JSObject {
  external int get size;
  external JSPromise<JSAny?> mapAsync(int mode);
  external JSArrayBuffer getMappedRange();
  external void unmap();
  external void destroy();
}

extension type _Texture._(JSObject _) implements JSObject {
  external JSObject createView();
  external void destroy();
}

/// A JS object of [values], with Dart numbers, strings, booleans, maps and
/// lists converted and JS values as they are.
JSObject _object(Map<String, Object?> values) {
  final object = JSObject();
  for (final MapEntry(:key, :value) in values.entries) {
    object[key] = _value(value);
  }
  return object;
}

JSAny? _value(Object? value) => switch (value) {
  null => null,
  int v => v.toJS,
  double v => v.toJS,
  bool v => v.toJS,
  String v => v.toJS,
  Map<String, Object?> v => _object(v),
  List<Object?> v => [for (final e in v) _value(e)].toJS,
  _ => value as JSAny,
};

// Usage flags of buffers and textures.
const _mapRead = 1, _copyDestination = 8;
const _vertexUsage = 32, _uniformUsage = 64;
const _textureCopySource = 1, _textureCopyDestination = 2;
const _textureBinding = 4, _renderAttachment = 16;
const _vertexStage = 1, _fragmentStage = 2;

const _colorFormat = 'rgba8unorm', _depthFormat = 'depth24plus-stencil8';

// WebGPU requires uniform offsets and copy rows in multiples of 256 bytes.
const _alignment = 256;
int _aligned(int bytes) => (bytes + _alignment - 1) & ~(_alignment - 1);

class _WebDevice implements GpuDevice {
  _WebDevice(this._device);

  final _Device _device;
  _Queue get _queue => _device.queue;

  // The vertices and the uniforms of a pass, written before the pass is
  // submitted. The queue runs the writes and the passes in order, so the
  // next pass can write over them. A buffer that grows is a new one, which
  // [_generation] counts for the bind groups that refer to it.
  _Buffer? _vertexBuffer, _uniformBuffer;
  int _generation = 0;
  final _samplers = <int, JSObject>{};
  int _textureIds = 0;

  @override
  String get name => 'WebGPU';

  @override
  String get readBack => 'submitted work, mapped buffer';

  @override
  bool get stencil => true;

  @override
  int get uniformAlignment => _alignment;

  @override
  Future<GpuProgram> program(GpuProgramSource source) async {
    final code = await rootBundle.loadString(source.wgsl);
    final module = _device.createShaderModule(_object({'code': code}));
    final bindings = [...source.bindings]
      ..sort((a, b) => a.binding.compareTo(b.binding));
    final layout = _device.createBindGroupLayout(
      _object({
        'entries': [
          for (final b in bindings)
            if (b.texture) ...[
              {
                'binding': b.binding,
                'visibility': _fragmentStage,
                'texture': {'sampleType': 'float'},
              },
              {
                'binding': b.binding + 1,
                'visibility': _fragmentStage,
                'sampler': {'type': 'filtering'},
              },
            ] else
              {
                'binding': b.binding,
                'visibility': b.vertex ? _vertexStage : _fragmentStage,
                'buffer': {'type': 'uniform', 'hasDynamicOffset': true},
              },
        ],
      }),
    );
    var offset = 0;
    final attributes = <Map<String, Object?>>[];
    for (final (i, floats) in source.attributes.indexed) {
      attributes.add({
        'shaderLocation': i,
        'offset': offset,
        'format': floats == 1 ? 'float32' : 'float32x$floats',
      });
      offset += floats * 4;
    }
    return _WebProgram(
      module,
      layout,
      _device.createPipelineLayout(
        _object({
          'bindGroupLayouts': [layout],
        }),
      ),
      bindings,
      {'arrayStride': offset, 'attributes': attributes},
      offset,
      source.cacheBindGroups,
    );
  }

  @override
  GpuTexture texture(int width, int height, Uint8List rgba) {
    final texture = _device.createTexture(
      _object({
        'size': [width, height],
        'format': 'rgba8unorm',
        'usage': _textureBinding | _textureCopyDestination,
      }),
    );
    _queue.writeTexture(
      _object({'texture': texture}),
      rgba.toJS,
      _object({'bytesPerRow': width * 4, 'rowsPerImage': height}),
      _object({'width': width, 'height': height}),
    );
    return _WebTexture(
      texture,
      texture.createView(),
      width,
      height,
      _textureIds++,
    );
  }

  @override
  GpuTarget target(int width, int height) {
    final color = _device.createTexture(
      _object({
        'size': [width, height],
        'format': _colorFormat,
        'usage': _renderAttachment | _textureCopySource | _textureBinding,
      }),
    );
    final depth = _device.createTexture(
      _object({
        'size': [width, height],
        'format': _depthFormat,
        'usage': _renderAttachment,
      }),
    );
    return _WebTarget(
      _WebTexture(color, color.createView(), width, height, _textureIds++),
      depth.createView(),
    );
  }

  @override
  GpuPass pass(
    GpuTarget target,
    GpuProgram program,
    List<Float32List> vertices, {
    required List<double> clearColor,
    required double clearDepth,
  }) => _WebPass(
    this,
    target as _WebTarget,
    program as _WebProgram,
    vertices,
    clearColor,
    clearDepth,
  );

  @override
  Future<void> settle() async {
    await _queue.onSubmittedWorkDone().toDart;
  }

  @override
  Future<Uint8List?> read(GpuTarget target) async {
    target as _WebTarget;
    final width = target.width, height = target.height;
    final row = _aligned(width * 4);
    final buffer = _device.createBuffer(
      _object({'size': row * height, 'usage': _mapRead | _copyDestination}),
    );
    try {
      final encoder = _device.createCommandEncoder();
      encoder.copyTextureToBuffer(
        _object({'texture': target.color}),
        _object({'buffer': buffer, 'bytesPerRow': row, 'rowsPerImage': height}),
        _object({'width': width, 'height': height}),
      );
      _queue.submit([encoder.finish()].toJS);
      await buffer.mapAsync(1).toDart;
      final mapped = buffer.getMappedRange().toDart.asUint8List();
      final rgba = Uint8List(width * height * 4);
      for (var y = 0; y < height; y++) {
        rgba.setRange(y * width * 4, (y + 1) * width * 4, mapped, y * row);
      }
      buffer.unmap();
      return rgba;
    } catch (_) {
      return null;
    } finally {
      buffer.destroy();
    }
  }

  /// A buffer of at least [bytes] for [usage], [current] if it is large
  /// enough.
  _Buffer _buffer(_Buffer? current, int bytes, int usage) {
    if (current != null && current.size >= bytes) return current;
    current?.destroy();
    _generation++;
    var size = _alignment;
    while (size < bytes) {
      size *= 2;
    }
    return _device.createBuffer(
      _object({'size': size, 'usage': usage | _copyDestination}),
    );
  }

  JSObject _sampler(GpuSampler sampler) =>
      _samplers[sampler.key] ??= _device.createSampler(
        _object({
          'magFilter': sampler.linear ? 'linear' : 'nearest',
          'minFilter': sampler.linear ? 'linear' : 'nearest',
          'addressModeU': _addresses[sampler.addressU.index],
          'addressModeV': _addresses[sampler.addressV.index],
        }),
      );

  static const _addresses = ['repeat', 'mirror-repeat', 'clamp-to-edge'];
}

class _WebProgram implements GpuProgram {
  _WebProgram(
    this.module,
    this.bindGroupLayout,
    this.layout,
    this.bindings,
    this.vertexLayout,
    this.vertexBytes,
    this.cacheBindGroups,
  );
  final JSObject module, bindGroupLayout, layout;
  // Sorted by binding.
  final List<GpuBinding> bindings;
  final Map<String, Object?> vertexLayout;
  final int vertexBytes;
  final bool cacheBindGroups;
  final pipelines = <int, JSObject>{};
  final bindGroups = <String, JSObject>{};
}

class _WebTexture implements GpuTexture {
  _WebTexture(this.texture, this.view, this.width, this.height, this.id);
  final _Texture texture;
  final JSObject view;
  @override
  final int width, height;
  final int id;
  // WebGPU destroys it after the work submitted so far.
  @override
  void dispose() => texture.destroy();
}

class _WebTarget implements GpuTarget {
  _WebTarget(this.colorTexture, this.depthView);
  @override
  final _WebTexture colorTexture;
  final JSObject depthView;
  _Texture get color => colorTexture.texture;
  JSObject get colorView => colorTexture.view;
  @override
  int get width => colorTexture.width;
  @override
  int get height => colorTexture.height;
}

/// A draw with the bindings and the state at its time.
class _Draw {
  _Draw(
    this.state,
    this.reference,
    this.uniforms,
    this.textures,
    this.first,
    this.count,
    this.array,
  );
  final GpuState state;
  final int reference;
  // The offsets of the uniform blocks and the textures, in the order of
  // the bindings.
  final List<int> uniforms;
  final List<(_WebTexture, GpuSampler)> textures;
  final int first, count, array;
}

/// Collects the draws and encodes them when the pass ends, when the size
/// of the uniforms is known.
class _WebPass implements GpuPass {
  _WebPass(
    this._device,
    this._target,
    this._program,
    this._vertices,
    this._clearColor,
    this._clearDepth,
  );

  final _WebDevice _device;
  final _WebTarget _target;
  final _WebProgram _program;
  final List<Float32List> _vertices;
  final List<double> _clearColor;
  final double _clearDepth;

  final _draws = <_Draw>[];
  final _uniformBytes = BytesBuilder(copy: false);
  final _uniformOffsets = <String, int>{};
  final _uniformSizes = <String, int>{};
  final _textures = <String, (_WebTexture, GpuSampler)>{};
  GpuState _state = const GpuState();
  int _reference = 0;

  // The last list of [uniformAt] and its offset in the uniforms.
  ByteData? _shared;
  int _sharedOffset = 0;

  @override
  void uniform(String name, ByteData data) {
    _uniformOffsets[name] = _addUniforms(data);
    _uniformSizes[name] = data.lengthInBytes;
  }

  @override
  void uniformAt(String name, ByteData data, int offset, int length) {
    if (!identical(data, _shared)) {
      _sharedOffset = _addUniforms(data);
      _shared = data;
    }
    _uniformOffsets[name] = _sharedOffset + offset;
    _uniformSizes[name] = length;
  }

  /// Appends [data] to the uniforms of the pass and returns its offset.
  int _addUniforms(ByteData data) {
    final offset = _uniformBytes.length;
    _uniformBytes.add(Uint8List.sublistView(data));
    final pad = _aligned(data.lengthInBytes) - data.lengthInBytes;
    if (pad > 0) _uniformBytes.add(Uint8List(pad));
    return offset;
  }

  @override
  void texture(
    String name,
    GpuTexture texture, [
    GpuSampler sampler = const GpuSampler(),
  ]) => _textures[name] = (texture as _WebTexture, sampler);

  @override
  void state(GpuState state) => _state = state;

  @override
  void stencilReference(int value) => _reference = value;

  @override
  void draw(int first, int count, [int array = 0]) {
    final uniforms = <int>[];
    final textures = <(_WebTexture, GpuSampler)>[];
    for (final b in _program.bindings) {
      if (b.texture) {
        textures.add(_textures[b.name]!);
      } else {
        uniforms.add(_uniformOffsets[b.name]!);
      }
    }
    _draws.add(
      _Draw(_state, _reference, uniforms, textures, first, count, array),
    );
  }

  @override
  void end({void Function(bool success)? onComplete}) {
    final device = _device, gpu = device._device, queue = device._queue;
    final program = _program;
    // The vertex arrays follow each other in one buffer.
    final offsets = <int>[];
    var vertexBytes = 0;
    for (final v in _vertices) {
      offsets.add(vertexBytes);
      vertexBytes += _aligned(v.lengthInBytes);
    }
    final uniforms = _uniformBytes.takeBytes();
    final vertexBuffer = device._vertexBuffer = device._buffer(
      device._vertexBuffer,
      vertexBytes,
      _vertexUsage,
    );
    final uniformBuffer = device._uniformBuffer = device._buffer(
      device._uniformBuffer,
      uniforms.length + _alignment,
      _uniformUsage,
    );
    for (final (i, v) in _vertices.indexed) {
      if (v.isNotEmpty) {
        queue.writeBuffer(
          vertexBuffer,
          offsets[i],
          Uint8List.sublistView(v).toJS,
        );
      }
    }
    if (uniforms.isNotEmpty) queue.writeBuffer(uniformBuffer, 0, uniforms.toJS);
    final encoder = gpu.createCommandEncoder();
    final pass = encoder.beginRenderPass(
      _object({
        'colorAttachments': [
          {
            'view': _target.colorView,
            'clearValue': {
              'r': _clearColor[0],
              'g': _clearColor[1],
              'b': _clearColor[2],
              'a': _clearColor[3],
            },
            'loadOp': 'clear',
            'storeOp': 'store',
          },
        ],
        'depthStencilAttachment': {
          'view': _target.depthView,
          'depthClearValue': _clearDepth,
          'depthLoadOp': 'clear',
          'depthStoreOp': 'discard',
          'stencilClearValue': 0,
          'stencilLoadOp': 'clear',
          'stencilStoreOp': 'discard',
        },
      }),
    );
    if (program.bindGroups.length > 4096) program.bindGroups.clear();
    var array = -1;
    for (final draw in _draws) {
      if (draw.array != array) {
        array = draw.array;
        pass.setVertexBuffer(0, vertexBuffer, offsets[array]);
      }
      pass.setPipeline(_pipeline(draw.state));
      pass.setBindGroup(
        0,
        _bindGroup(draw, uniformBuffer),
        [for (final o in draw.uniforms) o.toJS].toJS,
      );
      pass.setStencilReference(draw.reference);
      pass.draw(draw.count, 1, draw.first);
    }
    pass.end();
    queue.submit([encoder.finish()].toJS);
    if (onComplete != null) {
      queue.onSubmittedWorkDone().toDart.then(
        (_) => onComplete(true),
        onError: (_) => onComplete(false),
      );
    }
  }

  JSObject _bindGroup(_Draw draw, _Buffer uniformBuffer) {
    final program = _program;
    if (!program.cacheBindGroups) return _createBindGroup(draw, uniformBuffer);
    final key = StringBuffer('${_device._generation}');
    for (final (texture, sampler) in draw.textures) {
      key.write(',${texture.id}:${sampler.key}');
    }
    for (final b in program.bindings) {
      if (!b.texture) key.write(',${_uniformSizes[b.name]}');
    }
    return program.bindGroups[key.toString()] ??=
        _createBindGroup(draw, uniformBuffer);
  }

  JSObject _createBindGroup(_Draw draw, _Buffer uniformBuffer) => _device._device
        .createBindGroup(
          _object({
            'layout': _program.bindGroupLayout,
            'entries': [
              for (final (b, texture) in _pairs(draw))
                if (texture != null) ...[
                  {'binding': b.binding, 'resource': texture.$1.view},
                  {
                    'binding': b.binding + 1,
                    'resource': _device._sampler(texture.$2),
                  },
                ] else
                  {
                    'binding': b.binding,
                    'resource': {
                      'buffer': uniformBuffer,
                      'size': _uniformSizes[b.name],
                    },
                  },
            ],
          }),
        );

  /// The bindings of the program with the texture of [draw] for each
  /// texture binding.
  Iterable<(GpuBinding, (_WebTexture, GpuSampler)?)> _pairs(_Draw draw) sync* {
    var t = 0;
    for (final b in _program.bindings) {
      yield (b, b.texture ? draw.textures[t++] : null);
    }
  }

  JSObject _pipeline(GpuState state) =>
      _program.pipelines[state.key] ??= _device._device.createRenderPipeline(
        _object({
          'layout': _program.layout,
          'vertex': {
            'module': _program.module,
            'entryPoint': 'vertex_main',
            'buffers': [_program.vertexLayout],
          },
          'fragment': {
            'module': _program.module,
            'entryPoint': 'fragment_main',
            'targets': [
              {
                'format': _colorFormat,
                if (state.blend)
                  'blend': {
                    for (final part in ['color', 'alpha'])
                      part: {
                        'operation': 'add',
                        'srcFactor': _factors[state.sourceFactor.index],
                        'dstFactor': _factors[state.destinationFactor.index],
                      },
                  },
              },
            ],
          },
          'primitive': {'topology': 'triangle-list', 'cullMode': 'none'},
          'depthStencil': {
            'format': _depthFormat,
            'depthWriteEnabled': state.depthWrite,
            'depthCompare': _compares[state.depthCompare.index],
            for (final face in ['stencilFront', 'stencilBack'])
              face: {
                'compare': _compares[state.stencilCompare.index],
                'failOp': 'keep',
                'depthFailOp': 'keep',
                'passOp': _operations[state.stencilOperation.index],
              },
            'stencilReadMask': state.stencilReadMask,
            'stencilWriteMask': state.stencilWriteMask,
          },
        }),
      );

  static const _compares = [
    'never',
    'less',
    'equal',
    'less-equal',
    'greater',
    'not-equal',
    'greater-equal',
    'always',
  ];

  static const _factors = [
    'zero',
    'one',
    'src',
    'one-minus-src',
    'src-alpha',
    'one-minus-src-alpha',
    'dst',
    'one-minus-dst',
    'dst-alpha',
    'one-minus-dst-alpha',
  ];

  static const _operations = ['keep', 'zero', 'replace', 'invert'];
}
