// Runs the DC core from a state and writes the inputs of renders to files,
// for web/dc_render_check.dart and bin/dc_replay.dart.
//
// dart run bin/dc_capture.dart STATE FRAMES OUT BOOT DISC [--bios FILE]
//     [--jit on|off] [--count N]
//
// Writes the first N (1) renders after FRAMES frames to OUT_0.dcr,
// OUT_1.dcr and so on.
//
// The headless session is imported from its directory, as it is not in a
// library of fnesemu_core.
import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:fnesemu_core/src/core/dc/dc_compute.dart';
import 'package:fnesemu_core/src/core/dc/gpu_render.dart';
import 'package:gs_compute_check/dc_capture.dart';
import 'package:gs_compute_check/sink.dart';

import '../../../packages/fnesemu_core/tool/headless/options.dart';
import '../../../packages/fnesemu_core/tool/headless/session.dart';

/// A compute program that writes the inputs of a render when it is
/// submitted, while [taking] is set.
class _Capture extends DcCompute {
  _Capture(super.sink, super.memory, this.render, this.take);

  final DcGpuRender render;
  final void Function(Uint8List capture) take;
  bool taking = false;

  @override
  void submit() {
    if (taking) take(captureRender(render));
    super.submit();
  }
}

Future<void> main(List<String> args) async {
  String option(String name, String fallback) {
    final i = args.indexOf(name);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
  }

  final positional = <String>[];
  for (var i = 0; i < args.length; i++) {
    if (args[i].startsWith('--')) {
      i++;
    } else {
      positional.add(args[i]);
    }
  }
  if (positional.length < 4) {
    stderr.writeln(
      'usage: STATE FRAMES OUT BOOT DISC [--bios FILE] '
      '[--jit on|off] [--count N]',
    );
    exit(64);
  }
  final [state, frameText, out, ...media] = positional;
  final count = int.parse(option('--count', '1'));
  final sink = WgpuComputeSink.open();
  if (sink == null) exit(2);
  final session = await Session.open(
    'dc',
    media,
    Options.parse(
      [
        '--frame-runner',
        for (final name in ['--bios', '--jit'])
          if (args.contains(name)) ...[name, option(name, '')],
      ],
      flags: mediaFlags,
      valued: mediaValued,
    ),
    recordAudio: false,
  );
  session.loadState(state);
  final render = (session.core as Dc).bus.gpu.render;
  var taken = 0;
  final capture = _Capture(sink, render.memory, render, (bytes) {
    File('${out}_$taken.dcr').writeAsBytesSync(bytes);
    stdout.writeln('${out}_$taken.dcr');
    taken++;
  });
  render.compute = capture;
  for (var i = 0; i < int.parse(frameText); i++) {
    await session.stepFrame();
  }
  capture.taking = true;
  while (taken < count) {
    if (!await session.stepFrame()) break;
  }
  capture.taking = false;
  session.core.computeSink = null;
  session.core.dispose();
}
