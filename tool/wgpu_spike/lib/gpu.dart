// dart:ffi bindings of native/gsgpu.c.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

typedef _MallocC = Pointer<Void> Function(IntPtr);
typedef _Malloc = Pointer<Void> Function(int);
final _malloc =
    DynamicLibrary.process().lookupFunction<_MallocC, _Malloc>('malloc');

/// native memory that lives as long as the process
Pointer<T> alloc<T extends NativeType>(int bytes) {
  final p = _malloc(bytes);
  if (p == nullptr) throw StateError('malloc $bytes');
  return p.cast<T>();
}

/// zeroed native words and their typed view
(Pointer<Uint32>, Uint32List) nativeWords(int count) {
  final p = alloc<Uint32>(count * 4);
  return (p, p.asTypedList(count)..fillRange(0, count, 0));
}

String _cString(Pointer<Uint8> p) {
  var n = 0;
  while (p[n] != 0) {
    n++;
  }
  return utf8.decode(p.asTypedList(n));
}

Pointer<Uint8> _zeroTerminated(String s) {
  final b = utf8.encode(s);
  final p = alloc<Uint8>(b.length + 1);
  p.asTypedList(b.length + 1)
    ..setAll(0, b)
    ..[b.length] = 0;
  return p;
}

typedef _InitC = Int32 Function(
    Pointer<Uint8>, Uint32, Pointer<Uint8>, Pointer<Uint8>, Int32);
typedef _Init = int Function(
    Pointer<Uint8>, int, Pointer<Uint8>, Pointer<Uint8>, int);
typedef _ErrorC = Pointer<Uint8> Function();
typedef _WriteC = Void Function(Pointer<Uint32>, Uint32, Uint32);
typedef _Write = void Function(Pointer<Uint32>, int, int);
typedef _ClutC = Void Function(Uint32, Pointer<Uint32>);
typedef _Clut = void Function(int, Pointer<Uint32>);
typedef _RunC = Int32 Function(Pointer<Uint32>, Uint32, Pointer<Uint32>,
    Pointer<Uint32>, Uint32, Pointer<Uint32>, Uint32, Uint32, Pointer<Double>);
typedef _Run = int Function(Pointer<Uint32>, int, Pointer<Uint32>,
    Pointer<Uint32>, int, Pointer<Uint32>, int, int, Pointer<Double>);
typedef _ReadC = Int32 Function(Pointer<Uint32>);
typedef _Read = int Function(Pointer<Uint32>);

class GsGpu {
  GsGpu._(DynamicLibrary lib)
      : _init = lib.lookupFunction<_InitC, _Init>('gsgpu_init'),
        _error = lib.lookupFunction<_ErrorC, _ErrorC>('gsgpu_error'),
        _write = lib.lookupFunction<_WriteC, _Write>('gsgpu_write_vram'),
        _clut = lib.lookupFunction<_ClutC, _Clut>('gsgpu_write_clut'),
        _run = lib.lookupFunction<_RunC, _Run>('gsgpu_run'),
        _read = lib.lookupFunction<_ReadC, _Read>('gsgpu_read_vram');

  final _Init _init;
  final _ErrorC _error;
  final _Write _write;
  final _Clut _clut;
  final _Run _run;
  final _Read _read;

  static const vramWords = 1024 * 1024;
  final (Pointer<Uint32>, Uint32List) _vram = nativeWords(vramWords);
  final (Pointer<Uint32>, Uint32List) _clutWords = nativeWords(512);
  final Pointer<Double> _times = alloc<Double>(3 * 8);

  /// the milliseconds of the last run to upload, to submit and to wait
  Float64List get times => _times.asTypedList(3);

  /// the adapter list of [open], the chosen one marked with '*'
  String adapters = '';

  /// Opens the shim at [library] on the first adapter whose description
  /// contains [adapter], on the Vulkan backend unless [backends] says other.
  static GsGpu open(String library, String wgsl,
      {String adapter = '', int backends = 1}) {
    final gpu = GsGpu._(DynamicLibrary.open(library));
    final info = alloc<Uint8>(4096)..value = 0;
    final status = gpu._init(_zeroTerminated(adapter), backends,
        _zeroTerminated(wgsl), info, 4096);
    gpu.adapters = _cString(info);
    if (status != 0) {
      throw StateError('gsgpu_init $status: ${_cString(gpu._error())}');
    }
    return gpu;
  }

  void _check(int status, String what) {
    if (status != 0) throw StateError('$what $status: ${_cString(_error())}');
  }

  void writeVram(Uint32List words) {
    _vram.$2.setAll(0, words);
    _write(_vram.$1, 0, vramWords);
  }

  void writeClut(int version, List<int> entries) {
    _clutWords.$2.setAll(0, entries);
    _clut(version, _clutWords.$1);
  }

  /// Runs the steps; unless [wait], only submits them.
  void run(Pointer<Uint32> steps, int count, Pointer<Uint32> params,
          Pointer<Uint32> prims, int primWords, Pointer<Uint32> data,
          int dataWords, {bool wait = true}) =>
      _check(_run(steps, count, params, prims, primWords, data, dataWords,
          wait ? 1 : 0, _times), 'gsgpu_run');

  Uint32List readVram() {
    _check(_read(_vram.$1), 'gsgpu_read_vram');
    return _vram.$2;
  }

  static String defaultLibrary() {
    final here = File(Platform.script.toFilePath()).parent.parent.path;
    return Platform.environment['GSGPU_LIB'] ?? '$here/build/libgsgpu.so';
  }
}
