// The device on WebGPU, on the thread of the page. WebGPU gives the results
// of the GPU only through promises, so a read cannot wait for them. Instead,
// [ComputeProgram.prefetch] copies a range and starts to map it,
// [ComputeProgram.fetching] completes when the range is mapped, and only then
// [ComputeProgram.read] takes it. [ComputeDevice.waits] is false, so that the
// caller awaits [ComputeProgram.fetching] at a point where it can stop.
//
// WebGPU reports the errors of its calls later, too: an error of the device,
// such as a shader that does not compile, makes the next call or read throw.
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'types.dart';

@JS('navigator.gpu')
external JSObject? get _gpu;

// GPUBufferUsage, GPUShaderStage and GPUMapMode
const _mapRead = 1, _copySource = 4, _copyDestination = 8;
const _uniform = 64, _storage = 128, _compute = 4, _read = 1;

const _limits = [
  'maxStorageBufferBindingSize',
  'maxBufferSize',
  'maxStorageBuffersPerShaderStage',
  'maxComputeWorkgroupStorageSize',
  'maxComputeInvocationsPerWorkgroup',
  'maxComputeWorkgroupsPerDimension',
];

JSObject _object(Map<String, JSAny?> fields) {
  final object = JSObject();
  for (final MapEntry(:key, :value) in fields.entries) {
    object[key] = value;
  }
  return object;
}

extension on JSObject {
  T call<T extends JSAny?>(
    String method, [
    List<JSAny?> arguments = const [],
  ]) => callMethodVarArgs<T>(method.toJS, arguments);
}

String _message(JSAny? error) {
  if (error.isA<JSObject>() && (error as JSObject).has('message')) {
    return (error['message'] as JSString).toDart;
  }
  return '$error';
}

class ComputeDevice {
  ComputeDevice._(this._device, this.name);

  static ComputeDevice? _prepared;
  static String? _failure;

  final JSObject _device;
  late final JSObject _queue = _device['queue'] as JSObject;
  String? _error;

  /// the description of the adapter
  final String name;

  String get adapters => '* $name';

  /// the WGPUInstanceBackend mask of the native platforms; unused here
  static const nativeBackends = 1 << 0 | 1 << 2 | 1 << 3;

  /// Opens the GPU, so that [open] and [adapterList] can answer at once.
  /// [onError] receives the reason when there is no GPU.
  static Future<void> prepare({void Function(String reason)? onError}) async {
    if (_prepared != null) return;
    if (_failure == null) {
      try {
        _prepared = await _request();
      } on Object catch (e) {
        _failure = e is ComputeException ? e.message : '$e';
      }
    }
    if (_failure != null) onError?.call(_failure!);
  }

  static Future<ComputeDevice> _request() async {
    final gpu = _gpu;
    if (gpu == null) throw ComputeException('no WebGPU in this browser');
    final adapter = await gpu.call<JSPromise<JSObject?>>('requestAdapter', [
      _object({'powerPreference': 'high-performance'.toJS}),
    ]).toDart;
    if (adapter == null) throw ComputeException('WebGPU found no adapter');
    final limits = adapter['limits'] as JSObject;
    final required = JSObject();
    for (final key in _limits) {
      required[key] = limits[key];
    }
    final device = await adapter.call<JSPromise<JSObject>>('requestDevice', [
      _object({'requiredLimits': required}),
    ]).toDart;
    final info = adapter['info'] as JSObject?;
    final parts = [
      for (final key in ['vendor', 'architecture', 'device', 'description'])
        if ((info?[key] as JSString?)?.toDart case final part?
            when part.isNotEmpty)
          part,
    ];
    final result = ComputeDevice._(
      device,
      '${parts.isEmpty ? 'GPU' : parts.join(' ')} (WebGPU)',
    );
    device.call('addEventListener', [
      'uncapturederror'.toJS,
      ((JSObject event) => result._fail(_message(event['error']))).toJS,
    ]);
    (device['lost'] as JSPromise<JSObject>).toDart.then(
      (info) => result._fail('GPU device lost: ${_message(info)}'),
    );
    return result;
  }

  void _fail(String message) => _error ??= message;

  void _check() {
    if (_error case final error?) throw ComputeException(error);
  }

  /// The adapter that [prepare] opened, if any.
  static List<String> adapterList({int backends = nativeBackends}) =>
      _prepared == null ? const [] : [_prepared!.name];

  /// The device that [prepare] opened. Returns null before it, or when the
  /// page has no GPU; [onError] receives the reason. [adapter] and
  /// [backends] are ignored, as WebGPU gives one adapter.
  static ComputeDevice? open({
    String adapter = '',
    int backends = nativeBackends,
    void Function(String reason)? onError,
  }) {
    final device = _prepared;
    if (device == null) {
      onError?.call(_failure ?? 'the GPU is not prepared');
    }
    return device;
  }

  /// Whether [ComputeProgram.read] and a run with `wait` wait for the GPU.
  /// False here: a read takes only a range that [ComputeProgram.fetching]
  /// has brought to the host.
  bool get waits => false;

  JSObject _buffer(int bytes, int usage) => _device.call('createBuffer', [
    _object({'size': bytes.toJS, 'usage': usage.toJS}),
  ]);

  /// Compiles the [entryPoints] of [wgsl] with [bindings]. A dispatch of a
  /// run sees block k of the parameters at [paramStride] bytes per block,
  /// for up to [maxDispatches] dispatches per run. The errors of the shader
  /// come later, and make a later call or read of the program throw.
  ComputeProgram program(
    String wgsl,
    List<String> entryPoints,
    List<ComputeBinding> bindings, {
    int paramStride = 256,
    int maxDispatches = 1,
  }) {
    _check();
    _device.call('pushErrorScope', ['validation'.toJS]);
    final module = _device.call<JSObject>('createShaderModule', [
      _object({'code': wgsl.toJS}),
    ]);
    final buffers = <JSObject>[];
    final entries = <JSAny>[], resources = <JSAny>[];
    var params = -1;
    for (final (binding, b) in bindings.indexed) {
      final JSObject buffer, layout;
      if (b.kind == ComputeBindingKind.params) {
        params = binding;
        final size = paramStride * maxDispatches;
        buffer = _buffer(size < 16 ? 16 : size, _uniform | _copyDestination);
        layout = _object({
          'type': 'uniform'.toJS,
          'hasDynamicOffset': true.toJS,
          'minBindingSize': b.bytes.toJS,
        });
        resources.add(
          _object({
            'binding': binding.toJS,
            'resource': _object({
              'buffer': buffer,
              'offset': 0.toJS,
              'size': b.bytes.toJS,
            }),
          }),
        );
      } else {
        final size = (b.bytes + 3) & ~3;
        buffer = _buffer(
          size < 4 ? 4 : size,
          _storage | _copyDestination | _copySource,
        );
        layout = _object({
          'type':
              (b.kind == ComputeBindingKind.storage
                      ? 'storage'
                      : 'read-only-storage')
                  .toJS,
        });
        resources.add(
          _object({
            'binding': binding.toJS,
            'resource': _object({'buffer': buffer}),
          }),
        );
      }
      buffers.add(buffer);
      entries.add(
        _object({
          'binding': binding.toJS,
          'visibility': _compute.toJS,
          'buffer': layout,
        }),
      );
    }
    final groupLayout = _device.call<JSObject>('createBindGroupLayout', [
      _object({'entries': entries.toJS}),
    ]);
    final layout = _device.call<JSObject>('createPipelineLayout', [
      _object({
        'bindGroupLayouts': [groupLayout].toJS,
      }),
    ]);
    final group = _device.call<JSObject>('createBindGroup', [
      _object({'layout': groupLayout, 'entries': resources.toJS}),
    ]);
    final pipes = [
      for (final entry in entryPoints)
        _device.call<JSObject>('createComputePipeline', [
          _object({
            'layout': layout,
            'compute': _object({'module': module, 'entryPoint': entry.toJS}),
          }),
        ]),
    ];
    final program = ComputeProgram._(
      this,
      buffers,
      params,
      group,
      pipes,
      paramStride,
    );
    _device.call<JSPromise<JSObject?>>('popErrorScope').toDart.then((error) {
      if (error != null) program._fail(_message(error));
    });
    return program;
  }

  /// Leaves the device open for the next [open].
  void close() {}
}

/// A range of a binding on its way to the host.
class _Fetch {
  _Fetch(this.offset, this.bytes, this.buffer);

  final int offset, bytes;
  final JSObject buffer;
  late final Future<void> future;
  bool settled = false;
  String? error;
}

class ComputeProgram {
  ComputeProgram._(
    this.device,
    this._buffers,
    this._params,
    this._group,
    this._pipes,
    this.paramStride,
  );

  final ComputeDevice device;
  final List<JSObject> _buffers;
  final int _params;
  final JSObject _group;
  final List<JSObject> _pipes;
  final int paramStride;

  /// the ranges of the last prefetch of each binding
  final _fetches = <int, _Fetch>{};
  String? _error;

  JSObject get _queue => device._queue;

  void _fail(String message) => _error ??= message;

  void _check() {
    device._check();
    if (_error case final error?) throw ComputeException(error);
  }

  /// Writes [words] from [start] to [end] at [byteOffset] of [binding], in
  /// queue order before the next run.
  void write(
    int binding,
    int byteOffset,
    Uint32List words, [
    int start = 0,
    int? end,
  ]) {
    _check();
    final data = Uint32List.sublistView(words, start, end ?? words.length);
    if (data.isEmpty) return;
    _queue.call('writeBuffer', [_buffers[binding], byteOffset.toJS, data.toJS]);
  }

  /// Submits [count] dispatches of 4 words in [dispatches] (entry point
  /// index and workgroup counts x, y and z) in order. Dispatch k sees the
  /// words of [params] from k * [paramStride] / 4. A run cannot wait here,
  /// so [wait] is ignored; later writes still take effect after the run.
  void run(
    Uint32List dispatches,
    int count,
    Uint32List params, {
    bool wait = true,
  }) {
    _check();
    if (_params >= 0 && count > 0) {
      final words = count * paramStride ~/ 4;
      write(_params, 0, params, 0, words < params.length ? words : null);
    }
    final commands = device._device.call<JSObject>('createCommandEncoder');
    final pass = commands.call<JSObject>('beginComputePass');
    var last = -1;
    for (var k = 0; k < count; k++) {
      final entry = dispatches[k * 4];
      final x = dispatches[k * 4 + 1],
          y = dispatches[k * 4 + 2],
          z = dispatches[k * 4 + 3];
      if (entry >= _pipes.length || x == 0 || y == 0 || z == 0) continue;
      if (entry != last) {
        pass.call('setPipeline', [_pipes[entry]]);
        last = entry;
      }
      pass.call('setBindGroup', [
        0.toJS,
        _group,
        if (_params >= 0) [(k * paramStride).toJS].toJS,
      ]);
      pass.call('dispatchWorkgroups', [x.toJS, y.toJS, z.toJS]);
    }
    pass.call('end');
    _queue.call('submit', [
      [commands.call<JSObject>('finish')].toJS,
    ]);
  }

  /// Copies [bytes] at [byteOffset] of [binding] after the runs so far and
  /// starts to map them. [fetching] completes when [read] can take them.
  /// A new prefetch of a binding drops the last range of that binding.
  void prefetch(int binding, int byteOffset, int bytes) {
    _check();
    _release(binding);
    final size = (bytes + 3) & ~3;
    final buffer = device._buffer(size, _mapRead | _copyDestination);
    final commands = device._device.call<JSObject>('createCommandEncoder');
    commands.call('copyBufferToBuffer', [
      _buffers[binding],
      byteOffset.toJS,
      buffer,
      0.toJS,
      size.toJS,
    ]);
    _queue.call('submit', [
      [commands.call<JSObject>('finish')].toJS,
    ]);
    final fetch = _fetches[binding] = _Fetch(byteOffset, bytes, buffer);
    fetch.future = buffer
        .call<JSPromise<JSAny?>>('mapAsync', [_read.toJS, 0.toJS, size.toJS])
        .toDart
        .then(
          (_) => fetch.settled = true,
          onError: (Object e) {
            fetch
              ..error = '$e'
              ..settled = true;
          },
        );
  }

  /// The ranges of the prefetches while they are not on the host; null when
  /// [read] can take them all, or when nothing is fetched.
  Future<void>? get fetching {
    final waiting = [
      for (final fetch in _fetches.values)
        if (!fetch.settled) fetch.future,
    ];
    return switch (waiting.length) {
      0 => null,
      1 => waiting.single,
      _ => Future.wait(waiting),
    };
  }

  /// Reads [target].length words at [byteOffset] of [binding], from the
  /// range of the last [prefetch] of [binding], once it has come. The range
  /// is then dropped. Throws when the range was not fetched or has not come.
  void read(int binding, int byteOffset, Uint32List target) {
    final bytes = target.lengthInBytes;
    if (bytes == 0) return;
    _check();
    final fetch = _fetches[binding];
    final start = byteOffset - (fetch?.offset ?? 0);
    if (fetch == null || start < 0 || start + bytes > fetch.bytes) {
      throw ComputeException('read of a range that no prefetch fetched');
    }
    if (!fetch.settled) {
      throw ComputeException('read before the prefetch has come');
    }
    if (fetch.error case final error?) throw ComputeException(error);
    final range = fetch.buffer.call<JSArrayBuffer>('getMappedRange', [
      0.toJS,
      fetch.buffer['size'],
    ]);
    target.setAll(0, range.toDart.asUint32List(start, target.length));
    _release(binding);
  }

  void _release(int binding) {
    // Destroying a buffer also ends its mapping, or one still on its way.
    _fetches.remove(binding)?.buffer.call('destroy');
  }

  void dispose() {
    for (final binding in [..._fetches.keys]) {
      _release(binding);
    }
    for (final buffer in _buffers) {
      buffer.call('destroy');
    }
  }
}
