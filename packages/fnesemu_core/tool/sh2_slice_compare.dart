// Compares CPU interleaving using shared media/input and output checks.
import 'dart:convert';
import 'dart:io';

import 'package:fnesemu_core/src/core.dart';
import 'package:fnesemu_core/src/core/md/md.dart';
import 'package:fnesemu_core/src/core/ss/ss.dart';

import 'headless/comparison.dart';
import 'headless/jit_metrics.dart';
import 'headless/options.dart';
import 'headless/session.dart';
import 'logging.dart';

int _hash(Iterable<int> values) {
  var h = 0x811c9dc5;
  for (final v in values) {
    h = ((h ^ v) * 0x01000193) & 0xffffffff;
  }
  return h;
}

final class _Variant {
  final String name;
  final int quantum;
  final String? output;
  final int endFrame;
  final Session session;
  final watch = Stopwatch();
  final images = <int>[], audio = <(int, int)>[];
  final differences = <String, int>{};
  final details = <String, Object>{};
  final batches = <int>[];
  late JitCounters countersStart;
  int audioHash = 0x811c9dc5, samples = 0;
  _Variant(this.name, this.quantum, this.session, this.output, this.endFrame) {
    session.core.onAudio((buf) {
      samples += buf.buffer.length;
      if (output != null) {
        session.sampleRate = buf.sampleRate;
        session.channels = buf.channels;
      }
      for (final v in buf.buffer) {
        final sample = (v.clamp(-1.0, 1.0) * 32767).round();
        audioHash = ((audioHash ^ sample) * 0x01000193) & 0xffffffff;
        if (output != null) {
          session.pcm.addByte(sample & 255);
          session.pcm.addByte((sample >> 8) & 255);
        }
      }
    });
  }
  Core get core => session.core;
  String get cpuState => switch (core) {
        Ss c =>
          '${c.master.dump()} ${c.master.clocks} ${c.slave.dump()} ${c.slave.clocks}',
        Md c =>
          '${c.cpuM68.pc} ${c.cpuM68.clocks} ${c.cpuZ80.r.pc} ${c.cpuZ80.cycles} '
              '${c.expansion!.cpus[0].dump()} ${c.expansion!.cpus[0].clocks} '
              '${c.expansion!.cpus[1].dump()} ${c.expansion!.cpus[1].clocks}',
        _ => throw StateError('Unsupported core'),
      };
  List<(int, List<int>)> get memories => switch (core) {
        Ss c => [(0x06000000, c.bus.wramH), (0x00200000, c.bus.wramL)],
        Md c => [(0x06000000, c.expansion!.ram), (0x00ff0000, c.busM68.ram)],
        _ => throw StateError('Unsupported core'),
      };
  Future<void> frame(bool timed) async {
    audioHash = 0x811c9dc5;
    samples = 0;
    if (timed) watch.start();
    final running = session.execFrame();
    final image = core.imageBuffer();
    watch.stop();
    if (!running) throw StateError('Stopped at ${session.frame}');
    images.add(_hash([image.width, image.height, _hash(image.buffer)]));
    audio.add((audioHash, samples));
    final next = session.frame + 1;
    if (output != null && (next % 300 == 0 || next == endFrame)) {
      savePng(image, framePath(output!, next));
    }
    await session.endFrame();
  }
}

Future<void> main(List<String> args) async {
  configureLogging();
  final o =
      Options.parse(args, valued: {'--case', '--warmup', '--frames', '--out'});
  final warm = o.integer('--warmup', 2800), frames = o.integer('--frames', 90);
  if (o['--case'] == null || warm < 0 || frames <= 0 || frames % 10 != 0) {
    throw ArgumentError('--case FILE --warmup N --frames N (multiple of 10)');
  }
  final config = (jsonDecode(File(o['--case']!).readAsStringSync()) as List)
      .cast<String>();
  final variants = <_Variant>[];
  try {
    final name = config.first;
    final plan = switch (name) {
      'ss' => [
          ('jit-32', true, 32),
          ('jit-64', true, 64),
          ('jit-128', true, 128)
        ],
      '32x' => [
          ('interp-1', false, 1),
          ('jit-1', true, 1),
          ('interp-32', false, 32),
          ('jit-32', true, 32),
          ('jit-64', true, 64)
        ],
      _ => throw ArgumentError('SS or 32x fixture required'),
    };
    for (final (label, jit, quantum) in plan) {
      final options = Options.parse([
        ...config,
        '--jit',
        jit ? 'on' : 'off',
        name == 'ss' ? '--ss-slice-clocks' : '--32x-slice-clocks',
        '$quantum',
        '--frame-runner',
        if (name == 'ss' && !config.contains('--fixed-clock')) '--fixed-clock',
      ], valued: mediaValued, flags: mediaFlags, aliases: mediaAliases);
      final (id, files) = coreAndFiles(options);
      final session =
          await Session.open(id, files, options, recordAudio: false);
      final output = o['--out'] == null ? null : '${o['--out']}/$label';
      if (output != null) Directory(output).createSync(recursive: true);
      variants.add(_Variant(label, quantum, session, output, warm + frames));
      if (jit && !session.core.jitEnabled) {
        throw StateError('Native JIT required');
      }
    }
    void check(int from) {
      final a = variants.first;
      for (final b in variants.skip(1)) {
        void difference(String name) =>
            b.differences.putIfAbsent(name, () => a.session.frame);
        for (var i = from; i < a.images.length; i++) {
          if (a.images[i] != b.images[i]) {
            b.differences.putIfAbsent('image', () => i + 1);
          }
          if (a.audio[i] != b.audio[i]) {
            b.differences.putIfAbsent('audio', () => i + 1);
          }
        }
        if (a.cpuState != b.cpuState) {
          difference('cpu');
          b.details.putIfAbsent('cpuBaseline', () => a.cpuState);
          b.details.putIfAbsent('cpuVariant', () => b.cpuState);
        }
        final x = a.memories, y = b.memories;
        if (List.generate(
                x.length, (i) => firstMismatch(x[i].$2, y[i].$2) != null)
            .any((v) => v)) {
          difference('ram');
          b.details.putIfAbsent(
              'ramBytes',
              () => [
                    for (var i = 0; i < x.length; i++)
                      ...differenceBytes(x[i].$1, x[i].$2, y[i].$2),
                  ]);
        }
      }
    }

    await runComparison(
      variants: variants,
      warmupFrames: warm,
      frames: frames,
      batchFrames: 10,
      warmupFrame: (v, _) => v.frame(false),
      afterWarmupFrame: (f) {
        if (f % 100 == 0) check(f - 100);
        if (f % 200 == 0) stderr.writeln('warmup $f/$warm');
      },
      afterWarmup: () {
        check(0);
        for (final v in variants) {
          v.countersStart = JitCounters(v.core);
        }
      },
      measureBatch: (v, interval) async {
        final before = v.watch.elapsedMicroseconds;
        for (var f = 0; f < interval.frames; f++) {
          await v.frame(true);
        }
        v.batches.add(v.watch.elapsedMicroseconds - before);
      },
      afterBatch: (interval) => check(interval.firstFrame - 1),
      afterMeasurements: () {
        for (final v in variants) {
          if (v.output != null && v.session.pcm.length > 0) {
            File('${v.output}/audio.wav').writeAsBytesSync(v.session.wav());
          }
        }
        print(jsonEncode([
          for (final v in variants)
            {
              'name': v.name,
              'jit': v.core.jitEnabled,
              'sliceClocks': v.quantum,
              'warmup': warm,
              'frames': frames,
              'msPerFrame': v.watch.elapsedMicroseconds / frames / 1000,
              'firstDifferenceFrame': v.differences,
              'firstDifferenceDetails': v.details,
              'measuredImageDifferences': [
                for (var f = warm; f < warm + frames; f++)
                  if (v.images[f] != variants.first.images[f]) f + 1
              ].length,
              'measuredAudioDifferences': [
                for (var f = warm; f < warm + frames; f++)
                  if (v.audio[f] != variants.first.audio[f]) f + 1
              ].length,
              ...JitCounters(v.core).since(v.countersStart),
              'batchesUs': v.batches,
            }
        ]));
      },
    );
  } finally {
    for (final v in variants) {
      v.core.dispose();
    }
  }
}
