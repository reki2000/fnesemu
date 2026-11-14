// Replays DC render captures of bin/dc_capture.dart in a browser, on the
// CPU and on WebGPU through mp_compute, and posts the differing pixels and
// the times to /report. The page lists the captures as ?c=NAME&c=NAME.
import 'dart:js_interop';

import 'package:fnesemu_core/src/core/dc/dc_compute.dart';
import 'package:gs_compute_check/dc_capture.dart';
import 'package:gs_compute_check/sink.dart';
import 'package:mp_compute/mp_compute.dart';

@JS('fetch')
external JSPromise<_Response> _fetch(String url, [JSObject? init]);

extension type _Response._(JSObject _) implements JSObject {
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

@JS('JSON.parse')
external JSObject _parse(String json);

@JS('JSON.stringify')
external String _stringify(String s);

Future<void> _report(String text) async {
  print(text);
  await _fetch(
    '/report',
    _parse('{"method":"POST","body":${_stringify(text)}}'),
  ).toDart;
}

Future<void> main() async {
  final lines = <String>[];
  String? failure;
  await ComputeDevice.prepare(onError: (r) => failure = r);
  final device = ComputeDevice.open(onError: (r) => failure ??= r);
  if (device == null) {
    await _report('NO DEVICE $failure');
    return;
  }
  final sink = WgpuComputeSink(device);
  lines.add('compute on ${sink.name}');
  DcCompute? compute;
  for (final name in Uri.base.queryParametersAll['c'] ?? const <String>[]) {
    final response = await _fetch(name).toDart;
    final capture = (await response.arrayBuffer().toDart).toDart.asUint8List();
    try {
      if (compute == null) {
        final clock = Stopwatch()..start();
        compute = DcCompute(sink, replayRenderer(capture).memory);
        lines.add('program made in ${clock.elapsedMilliseconds} ms');
      }
      final (cpu, cpuUs) = await replay(capture, null, rounds: 3);
      final (gpu, gpuUs) = await replay(capture, compute, rounds: 3);
      lines.add(
        '$name: over8 ${over8(capture, cpu, gpu)}, '
        'cpu ${(cpuUs / 1000).toStringAsFixed(2)} ms, '
        'compute ${(gpuUs / 1000).toStringAsFixed(2)} ms',
      );
    } on Object catch (e) {
      lines.add('$name: ERROR $e');
    }
  }
  await _report(lines.join('\n'));
}
