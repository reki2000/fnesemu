// synthetic benchmarks that need no ROM
//
// usage: dart run tool/microbench.dart <name> [args...]
//   vr4300                 the VR4300 (N64) interpreter on two instruction loops
//   video-debug [core...]  the debug video captures of each core (all by default)
import 'dart:io';

import 'microbench/video_debug.dart' as video_debug;
import 'microbench/vr4300.dart' as vr4300;

void main(List<String> args) {
  switch (args.firstOrNull) {
    case "vr4300":
      vr4300.main();
    case "video-debug":
      video_debug.main(args.sublist(1));
    default:
      stderr.writeln("usage: microbench <vr4300|video-debug> [args...]");
      exit(64);
  }
}
