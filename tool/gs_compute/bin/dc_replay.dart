// Replays DC render captures of bin/dc_capture.dart on the CPU and on the
// compute program, and prints the differing pixels and the times, as
// web/dc_render_check.dart does in a browser.
//
// dart run bin/dc_replay.dart CAPTURE... [--adapter NAME]
import 'dart:io';

import 'package:fnesemu_core/src/core/dc/dc_compute.dart';
import 'package:gs_compute_check/dc_capture.dart';
import 'package:gs_compute_check/sink.dart';

Future<void> main(List<String> args) async {
  final i = args.indexOf('--adapter');
  final adapter = i >= 0 ? args[i + 1] : '';
  final files = [
    for (var k = 0; k < args.length; k++)
      if (args[k] != '--adapter' && (k == 0 || args[k - 1] != '--adapter'))
        args[k],
  ];
  final sink = WgpuComputeSink.open(adapter: adapter);
  if (sink == null) exit(2);
  print('compute on ${sink.name}');
  DcCompute? compute;
  for (final file in files) {
    final capture = File(file).readAsBytesSync();
    compute ??= DcCompute(sink, replayRenderer(capture).memory);
    final (cpu, cpuUs) = await replay(capture, null, rounds: 10);
    final (gpu, gpuUs) = await replay(capture, compute, rounds: 10);
    print(
      '$file: over8 ${over8(capture, cpu, gpu)}, '
      'cpu ${(cpuUs / 1000).toStringAsFixed(2)} ms, '
      'compute ${(gpuUs / 1000).toStringAsFixed(2)} ms',
    );
  }
  compute?.dispose();
}
