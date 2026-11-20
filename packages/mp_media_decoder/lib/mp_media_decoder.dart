/// Decodes H.264 video and ATRAC3plus audio: H.264 through the decoder of
/// the operating system, and ATRAC3plus through a shared libavcodec that is
/// loaded at run time.
library;

export 'src/decoders_native.dart'
    if (dart.library.js_interop) 'src/decoders_web.dart';
export 'src/types.dart';
