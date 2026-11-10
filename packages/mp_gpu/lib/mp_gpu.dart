/// Offscreen drawing on the GPU of the platform: Flutter GPU on native
/// platforms and WebGPU on the Web. [GpuDevice.create] picks the API and
/// returns null when none is available.
library;

export 'src/gpu.dart';
export 'src/queue.dart';
