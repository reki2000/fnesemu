// Opens the compute GPU that the app gives the cores as a ComputeSink:
// wgpu-native through mp_compute on native platforms, none on the Web.
export 'compute_sink_native.dart'
    if (dart.library.js_interop) 'compute_sink_web.dart';
