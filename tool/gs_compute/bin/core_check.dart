// Runs the whole core from a state twice, once on the CPU and once with the
// compute program attached as the app attaches it (the computeSink of the
// core), and compares the pictures of each frame.
//
// dart run bin/core_check.dart STATE FRAMES OUT MEDIA... [--core NAME]
//     [--bios FILE] [--jit on|off] [--adapter NAME] [--max-over8 N]
//     [--warmup N]
//
// --core is ps2 (the default) or dc. MEDIA are the BIOS and the disc, or
// for dc the boot ROM and the disc, with the flash as --bios. Writes the last pictures as software.png
// and compute.png to OUT, and prints the time per frame of both runs. Exits
// with 1 when a picture has more than --max-over8 (16) pixels that differ by
// more than 8 in a channel, as the compute GS interpolates in 32-bit floats.
// --warmup runs N frames before the FRAMES that are timed and compared.
//
// The headless session is imported from its directory, as it is not in a
// library of fnesemu_core.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu_core/app_api.dart';
import 'package:gs_compute_check/sink.dart';

import '../../../packages/fnesemu_core/tool/headless/options.dart';
import '../../../packages/fnesemu_core/tool/headless/session.dart';

Future<(List<Uint32List>, ImageBuffer, double)> run(
  String core,
  List<String> options,
  String state,
  int frames,
  List<String> media,
  ComputeSink? sink, {
  int warmup = 0,
}) async {
  final session = await Session.open(
    core,
    media,
    Options.parse(
      ['--frame-runner', ...options],
      flags: mediaFlags,
      valued: mediaValued,
    ),
    recordAudio: false,
  );
  session.loadState(state);
  session.core.computeSink = sink;
  final pictures = <Uint32List>[];
  late ImageBuffer last;
  for (var i = 0; i < warmup; i++) {
    if (!await session.stepFrame()) throw StateError('core stopped');
  }
  final clock = Stopwatch()..start();
  for (var i = 0; i < frames; i++) {
    if (!await session.stepFrame()) throw StateError('core stopped');
    last = session.core.imageBuffer();
    pictures.add(Uint32List.fromList(last.buffer));
  }
  final ms = clock.elapsedMicroseconds / 1000 / frames;
  session.core.computeSink = null;
  session.core.dispose();
  return (pictures, last, ms);
}

Future<void> main(List<String> args) async {
  String option(String name, String fallback) {
    final i = args.indexOf(name);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
  }

  final positional = <String>[];
  for (var i = 0; i < args.length; i++) {
    // an option takes the next argument as its value
    if (args[i].startsWith('--')) {
      i++;
    } else {
      positional.add(args[i]);
    }
  }
  if (positional.length < 4) {
    stderr.writeln('usage: STATE FRAMES OUT MEDIA... [--core NAME] '
        '[--bios FILE] [--jit on|off] [--adapter NAME] [--max-over8 N] '
        '[--warmup N]');
    exit(64);
  }
  final [state, frameText, out, ...media] = positional;
  final frames = int.parse(frameText);
  final core = option('--core', 'ps2');
  final options = [
    for (final name in ['--bios', '--jit'])
      if (args.contains(name)) ...[name, option(name, '')],
  ];
  final maxOver8 = int.parse(option('--max-over8', '16'));
  final warmup = int.parse(option('--warmup', '0'));

  final gpu = WgpuComputeSink.open(adapter: option('--adapter', ''));
  if (gpu == null) exit(2);
  stdout.writeln('compute on ${gpu.name}');

  final (software, softwareLast, softwareMs) = await run(
    core,
    options,
    state,
    frames,
    media,
    null,
    warmup: warmup,
  );
  final (compute, computeLast, computeMs) = await run(
    core,
    options,
    state,
    frames,
    media,
    gpu,
    warmup: warmup,
  );

  var worst = 0;
  for (var f = 0; f < frames; f++) {
    final a = software[f], b = compute[f];
    var over8 = 0, differing = 0;
    if (a.length != b.length) {
      over8 = a.length;
    } else {
      for (var i = 0; i < a.length; i++) {
        if (a[i] == b[i]) continue;
        differing++;
        for (var s = 0; s < 32; s += 8) {
          if (((a[i] >> s & 0xff) - (b[i] >> s & 0xff)).abs() > 8) {
            over8++;
            break;
          }
        }
      }
    }
    if (over8 > worst) worst = over8;
    if (differing > 0) {
      stdout.writeln(
        jsonEncode({
          'frame': f + 1,
          'pixelsDiffering': differing,
          'over8': over8,
        }),
      );
    }
  }
  Directory(out).createSync(recursive: true);
  savePng(softwareLast, '$out/software.png');
  savePng(computeLast, '$out/compute.png');
  stdout.writeln(
    jsonEncode({
      'frames': frames,
      'softwareMsPerFrame': softwareMs,
      'computeMsPerFrame': computeMs,
      'worstOver8': worst,
    }),
  );
  stdout.writeln(worst <= maxOver8 ? 'PASS' : 'FAIL');
  exit(worst <= maxOver8 ? 0 : 1);
}
