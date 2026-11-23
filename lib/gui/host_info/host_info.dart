/// What the benchmark records about the machine: the OS, the CPU model,
/// its cores and their clocks.
library;

export 'host_info_io.dart' if (dart.library.js_interop) 'host_info_web.dart';
