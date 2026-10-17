/// Converts RGBA frames for the platform image decoder.
library;

export 'src/host_pixels_io.dart'
    if (dart.library.js_interop) 'src/host_pixels_web.dart';
