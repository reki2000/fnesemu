import 'dart:convert';
import 'dart:io';

import 'package:fnesemu_core/src/core/ps2/gs/gs.dart';

import '../../packages/fnesemu_core/tool/headless/options.dart';
import '../../packages/fnesemu_core/tool/headless/session.dart';

Future<void> main(List<String> args) async {
  final config = jsonDecode(File(args[0]).readAsStringSync()) as Map;
  final count = int.parse(args[1]);
  final session = await Session.open(
    'ps2',
    List<String>.from(config['files'] as List),
    Options.parse(
      ['--frame-runner', '--input', (config['input'] ?? '') as String],
      flags: mediaFlags,
      valued: mediaValued,
    ),
    recordAudio: false,
  );
  final start = (config['frame'] as int) - 1;
  final samples = <Map<String, Object?>>[];
  try {
    session.loadState(config['state'] as String);
    while (session.frame < start) {
      if (!await session.stepFrame()) throw StateError('warmup stopped');
      session.core.imageBuffer();
    }
    if (session.frame != start) throw StateError('unexpected start frame');
    final drawClock = gsDrawStopwatch = Stopwatch();
    final timer = Stopwatch()..start();
    for (var n = 0; n < count; n++) {
      drawClock.reset();
      final begin = timer.elapsedMicroseconds;
      if (!session.execFrame()) throw StateError('emulator stopped');
      final rendered = timer.elapsedMicroseconds;
      await session.endFrame();
      final ended = timer.elapsedMicroseconds;
      session.core.imageBuffer();
      final displayed = timer.elapsedMicroseconds;
      samples.add({
        'frame': session.frame,
        'coreUs': rendered - begin,
        'drawUs': drawClock.elapsedMicroseconds,
        'endFrameUs': ended - rendered,
        'imageUs': displayed - ended,
        'totalUs': displayed - begin,
      });
    }
  } finally {
    gsDrawStopwatch = null;
    session.core.dispose();
  }
  stdout.writeln(jsonEncode({'mode': 'headless-software-aot', 'samples': samples}));
}
