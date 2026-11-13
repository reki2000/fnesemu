/// Compute programs on the platform GPU through wgpu-native.
///
/// A [ComputeDevice] compiles WGSL into a [ComputeProgram]: entry points that
/// share the buffers of bind group 0. Dart writes and reads the buffers and
/// runs lists of dispatches in order.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'src/native.dart';

/// How a program binds a buffer.
enum ComputeBindingKind {
  /// `var<storage, read_write>`
  storage,

  /// `var<storage, read>`
  readOnlyStorage,

  /// a `var<uniform>` block per dispatch, bound with a dynamic offset; at
  /// most one binding of a program
  params,
}

/// A buffer of a program at the binding of its index. For
/// [ComputeBindingKind.params], [bytes] is the size of the block that a
/// dispatch sees.
class ComputeBinding {
  const ComputeBinding(this.kind, this.bytes);

  final ComputeBindingKind kind;
  final int bytes;
}

class ComputeException implements Exception {
  ComputeException(this.message);

  final String message;

  @override
  String toString() => 'ComputeException: $message';
}

Pointer<Uint8> _cString(String s) {
  final b = utf8.encode(s);
  final p = malloc<Uint8>(b.length + 1);
  p.asTypedList(b.length + 1)
    ..setAll(0, b)
    ..[b.length] = 0;
  return p;
}

String _string(Pointer<Uint8> p) {
  var n = 0;
  while (p[n] != 0) {
    n++;
  }
  return utf8.decode(p.asTypedList(n));
}

/// [bytes] of native memory for a C string, or null when the platform has
/// no shim
Pointer<Uint8>? _infoBuffer(int bytes) {
  try {
    return malloc<Uint8>(bytes)..value = 0;
  } on ArgumentError {
    // the native asset is missing on this platform
    return null;
  }
}

class ComputeDevice {
  ComputeDevice._(this._device, this.adapters);

  final Pointer<MpcDevice> _device;

  /// the adapters that the device chose from, one per line, the chosen one
  /// marked with '*'
  final String adapters;

  /// the description of the chosen adapter
  String get name => adapters
      .split('\n')
      .firstWhere((l) => l.startsWith('* '), orElse: () => '* GPU')
      .substring(2);

  /// the WGPUInstanceBackend mask of Vulkan, Metal and Direct3D 12, the
  /// backends that the platforms run compute on
  static const nativeBackends = 1 << 0 | 1 << 2 | 1 << 3;

  /// The descriptions of the adapters on [backends], such as
  /// "name (Vulkan, discrete)", without opening a device. Empty when the
  /// platform has no shim. [open] takes a description as its adapter.
  static List<String> adapterList({int backends = nativeBackends}) {
    final info = _infoBuffer(16384);
    if (info == null) return const [];
    try {
      mpc_adapters(backends, info, 16384);
      return [
        for (final l in _string(info).split('\n'))
          if (l.isNotEmpty) l,
      ];
    } finally {
      free(info.cast());
    }
  }

  /// Opens the first adapter whose description contains [adapter], or the
  /// first discrete GPU (else the first adapter) when [adapter] is empty, on
  /// the backends of the WGPUInstanceBackend mask [backends] (0 for all).
  /// Returns null when the platform has no shim or no such adapter; [onError]
  /// receives the reason.
  static ComputeDevice? open({
    String adapter = '',
    int backends = nativeBackends,
    void Function(String reason)? onError,
  }) {
    final info = _infoBuffer(4096);
    if (info == null) {
      onError?.call('no compute shim on this platform');
      return null;
    }
    final name = _cString(adapter);
    final Pointer<MpcDevice> device;
    try {
      device = mpc_device_open(name, backends, info, 4096);
    } finally {
      free(name.cast());
    }
    final adapters = _string(info);
    free(info.cast());
    if (device == nullptr) {
      onError?.call('out of memory');
      return null;
    }
    final error = _string(mpc_error(device));
    if (error.isNotEmpty) {
      onError?.call('$error\n$adapters');
      mpc_device_close(device);
      return null;
    }
    return ComputeDevice._(device, adapters);
  }

  /// Compiles the [entryPoints] of [wgsl] with [bindings]. A dispatch of a
  /// run sees block k of the parameters at [paramStride] bytes per block,
  /// for up to [maxDispatches] dispatches per run.
  ComputeProgram program(
    String wgsl,
    List<String> entryPoints,
    List<ComputeBinding> bindings, {
    int paramStride = 256,
    int maxDispatches = 1,
  }) {
    final source = _cString(wgsl);
    final names = [for (final e in entryPoints) _cString(e)];
    final entries = malloc<Pointer<Uint8>>(8 * names.length);
    for (var i = 0; i < names.length; i++) {
      entries[i] = names[i];
    }
    final kinds = malloc<Uint32>(4 * bindings.length);
    final sizes = malloc<Uint64>(8 * bindings.length);
    for (var i = 0; i < bindings.length; i++) {
      kinds[i] = bindings[i].kind.index;
      sizes[i] = bindings[i].bytes;
    }
    try {
      final p = mpc_program_create(
        _device,
        source,
        entries,
        names.length,
        kinds,
        sizes,
        bindings.length,
        paramStride,
        maxDispatches,
      );
      if (p == nullptr) throw ComputeException(_string(mpc_error(_device)));
      return ComputeProgram._(this, p, paramStride, maxDispatches);
    } finally {
      for (final n in names) {
        free(n.cast());
      }
      for (final p in [source, entries, kinds, sizes]) {
        free(p.cast());
      }
    }
  }

  void _check(int status, String what) {
    if (status != 0) {
      throw ComputeException('$what: ${_string(mpc_error(_device))}');
    }
  }

  void close() => mpc_device_close(_device);
}

class ComputeProgram {
  ComputeProgram._(
    this.device,
    this._program,
    this.paramStride,
    this.maxDispatches,
  );

  final ComputeDevice device;
  final Pointer<MpcProgram> _program;
  final int paramStride, maxDispatches;

  /// Writes [words] from [start] to [end] at [byteOffset] of [binding], in
  /// queue order before the next run.
  void write(
    int binding,
    int byteOffset,
    Uint32List words, [
    int start = 0,
    int? end,
  ]) {
    final view = Uint32List.sublistView(words, start, end);
    device._check(
      mpc_write(
        _program,
        binding,
        byteOffset,
        view.address.cast(),
        view.lengthInBytes,
      ),
      'write',
    );
  }

  /// Runs [count] dispatches of 4 words in [dispatches] (entry point index
  /// and workgroup counts x, y and z) in order. Dispatch k sees the words of
  /// [params] from k * [paramStride] / 4. Unless [wait], the run is only
  /// submitted, and later writes still take effect after it.
  void run(
    Uint32List dispatches,
    int count,
    Uint32List params, {
    bool wait = true,
  }) {
    device._check(
      mpc_run(
        _program,
        dispatches.address,
        count,
        params.address.cast(),
        wait ? 1 : 0,
      ),
      'run',
    );
  }

  /// Waits for the program and reads [target].length words at [byteOffset]
  /// of [binding].
  void read(int binding, int byteOffset, Uint32List target) {
    device._check(
      mpc_read(
        _program,
        binding,
        byteOffset,
        target.address.cast(),
        target.lengthInBytes,
      ),
      'read',
    );
  }

  void dispose() => mpc_program_destroy(_program);
}
