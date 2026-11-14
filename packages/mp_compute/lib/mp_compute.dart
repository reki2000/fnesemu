/// Compute programs on the platform GPU through wgpu-native, and through
/// WebGPU on the Web.
///
/// A `ComputeDevice` compiles WGSL into a `ComputeProgram`: entry points that
/// share the buffers of bind group 0. Dart writes and reads the buffers and
/// runs lists of dispatches in order.
library;

export 'src/device_native.dart'
    if (dart.library.js_interop) 'src/device_web.dart';
export 'src/types.dart';
