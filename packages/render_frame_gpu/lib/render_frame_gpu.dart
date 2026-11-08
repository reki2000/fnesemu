/// Draws the render frames of a core with Flutter GPU. On platforms without
/// Flutter GPU, [GpuFrameSink.create] returns null.
library;

export 'src/gpu_frame_sink_stub.dart'
    if (dart.library.io) 'src/gpu_frame_sink.dart';
