// Checks how soon the pixels of a pass can be read back on this platform.
//
// For each case the probe draws frames into one target. Each frame uploads
// a small texture that holds the frame number and fills the target with it,
// so the center pixel tells which frame a read returned. A case waits in
// one way between the end of the passes and the reads, and counts the
// reads that returned the frame and each older frame. The cases cover each
// wait with and without large texture uploads in each frame, as a busy
// frame of a core does, and with one or four targets drawn before the
// reads, so one run shows the best wait of a platform.
//
// The results go to the log as lines that start with `MP_GPU_PROBE `, one
// JSON object for each case, then a `MP_GPU_PROBE_BEST ` line that ranks
// the waits by wrong reads and latency, and `MP_GPU_PROBE_DONE`. The
// latency of a case runs from the draws to the last read. A native build
// also writes them to the file named by the environment variable
// `MP_GPU_PROBE_OUT` and exits.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:mp_gpu/mp_gpu.dart';

import 'finish_stub.dart' if (dart.library.io) 'finish_io.dart';

void main() => runApp(const ProbeApp());

class ProbeApp extends StatefulWidget {
  const ProbeApp({super.key});

  @override
  State<ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<ProbeApp> {
  final _lines = <String>[];

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  void _log(String line) {
    debugPrint(line);
    setState(() => _lines.add(line));
  }

  Future<void> _run() async {
    // Lets the first frame of the window show before the probe starts.
    await Future.any([
      SchedulerBinding.instance.endOfFrame,
      Future<void>.delayed(const Duration(seconds: 3)),
    ]);
    try {
      _log('MP_GPU_PROBE_STEP device');
      final device = await GpuDevice.create();
      if (device == null) {
        _log('MP_GPU_PROBE ${jsonEncode({'error': 'no device'})}');
      } else {
        _log('MP_GPU_PROBE_STEP program ${device.name}');
        final probe = await _Probe.create(device);
        final results = <Map<String, Object?>>[];
        for (final uploads in _uploads) {
          for (final targets in _targets) {
            for (final wait in _Wait.values) {
              _log('MP_GPU_PROBE_STEP ${wait.name} $uploads $targets');
              final result = await probe.run(wait, uploads, targets);
              results.add(result);
              _log('MP_GPU_PROBE ${jsonEncode(result)}');
            }
          }
        }
        _log('MP_GPU_PROBE_BEST ${jsonEncode(_best(results))}');
      }
    } catch (e) {
      _log('MP_GPU_PROBE ${jsonEncode({'error': '$e'})}');
    }
    _log('MP_GPU_PROBE_DONE');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    finishProbe(_lines);
  }

  // The waits ranked by the reads that were not right over all cases,
  // then by the worst p90 latency of a case.
  static Map<String, Object?> _best(List<Map<String, Object?>> results) {
    final reads = <String, int>{}, wrong = <String, int>{};
    final worst = <String, double>{};
    for (final r in results) {
      final wait = r['wait']! as String;
      final n = r['reads']! as int;
      reads.update(wait, (v) => v + n, ifAbsent: () => n);
      final bad = n - (r['behind0'] as int? ?? 0);
      wrong.update(wait, (v) => v + bad, ifAbsent: () => bad);
      final p90 = double.parse(r['p90ms']! as String);
      worst.update(wait, (v) => v > p90 ? v : p90, ifAbsent: () => p90);
    }
    final waits = reads.keys.toList()
      ..sort((a, b) {
        final c = wrong[a]!.compareTo(wrong[b]!);
        return c != 0 ? c : worst[a]!.compareTo(worst[b]!);
      });
    return {
      'platform': results.first['platform'],
      'ranking': [
        for (final w in waits)
          '$w wrong ${wrong[w]}/${reads[w]} p90 '
              '${worst[w]!.toStringAsFixed(2)}ms',
      ],
    };
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: ListView(
        children: [
          for (final line in _lines)
            Text(line, style: const TextStyle(fontSize: 11)),
        ],
      ),
    ),
  );
}

// The number of large textures that each frame uploads besides its own.
const _uploads = [0, 16];

// The number of targets drawn before the reads, as the sink draws the
// frames that waited together.
const _targets = [1, 4];

// The ways to wait between the end of the passes and the reads. Each read
// is a GpuDevice.read, which reads twice on Flutter GPU.
enum _Wait {
  // Reads at once.
  none,
  // Waits for the completion callbacks of the passes.
  complete,
  // Waits for a timer of 1, 4 or 16 ms.
  delay1,
  delay4,
  delay16,
  // Waits for one or two frames of the engine.
  frame,
  frame2,
  // Waits for the completion callbacks and then a frame.
  completeFrame,
  // Waits for GpuDevice.settle.
  settle,
  // Reads again at once, up to 8 times, until the read is right.
  poll,
}

class _Probe {
  _Probe._(this.device, this._program, this._allTargets);

  static const _size = 64;
  static const _frames = 60;
  static const _polls = 8;

  static const _source = GpuProgramSource(
    bundle: 'shaders/probe.shaderbundle',
    vertexEntry: 'ProbeVertex',
    fragmentEntry: 'ProbeFragment',
    wgsl: 'shaders/probe.wgsl',
    attributes: [2, 2],
    bindings: [GpuBinding.uniform('Info', 0), GpuBinding.texture('image', 1)],
  );

  static Future<_Probe> create(GpuDevice device) async => _Probe._(
    device,
    await device.program(_source),
    [for (var i = 0; i < 4; i++) device.target(_size, _size)],
  );

  final GpuDevice device;
  final GpuProgram _program;
  final List<GpuTarget> _allTargets;
  int _frame = 0;

  // A triangle over the whole target, and a tiny one in a corner for the
  // large textures. The vertices hold x and y in clip space and u and v.
  static final _vertices = Float32List.fromList([
    -1, -1, 0, 0, 3, -1, 0, 0, -1, 3, 0, 0, //
    -1, 1, 0, 0, -0.99, 1, 0, 0, -1, 0.99, 0, 0,
  ]);
  static final _white = ByteData.sublistView(
    Float32List.fromList([1, 1, 1, 1]),
  );

  // The color of frame [n]: red and green hold its number.
  static int _color(int n) => 0xff5a0000 | (n >> 8 & 0xff) << 8 | (n & 0xff);

  // Draws frame [n] into [target] and returns when its pass completes.
  Future<void> _draw(GpuTarget target, int n, int uploads, Uint8List big) {
    final c = _color(n);
    final texture = device.texture(
      1,
      1,
      Uint8List.fromList([c & 0xff, c >> 8 & 0xff, c >> 16 & 0xff, 255]),
    );
    final extra = [
      for (var j = 0; j < uploads; j++)
        device.texture(256, 256, big..fillRange(0, 4, n + j & 0xff)),
    ];
    final pass = device.pass(
      target,
      _program,
      [_vertices],
      clearColor: const [0.5, 0.5, 0.5, 1],
      clearDepth: 1,
    );
    pass.uniform('Info', _white);
    for (final t in extra) {
      pass.texture('image', t);
      pass.draw(3, 3);
    }
    pass.texture('image', texture);
    pass.draw(0, 3);
    final completed = Completer<bool>();
    pass.end(onComplete: completed.complete);
    return completed.future;
  }

  // `behind0` is the frame itself, `behind1` the frame before, and
  // `behind3+` three or more frames before.
  static String _kind(Uint8List? rgba, int n) => switch (rgba) {
    null => 'null',
    _ => switch (_pixel(rgba)) {
      0xff808080 || 0xff7f7f7f => 'clear',
      final p when p >> 16 == 0xff5a && n - (p & 0xffff) >= 0 => switch (n -
          (p & 0xffff)) {
        final d when d < 3 => 'behind$d',
        _ => 'behind3+',
      },
      _ => 'other',
    },
  };

  Future<Map<String, Object?>> run(_Wait wait, int uploads, int count) async {
    final targets = _allTargets.sublist(0, count);
    final counts = <String, int>{};
    // A wait that does not end within 3 s counts as `timeout` and lets the
    // case go on, so a backend that stalls still gives a result.
    Future<T?> limit<T>(Future<T?> future) => future
        .then<T?>((v) => v)
        .timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            counts.update('timeout', (v) => v + 1, ifAbsent: () => 1);
            return null;
          },
        );
    void add(String kind) =>
        counts.update(kind, (v) => v + 1, ifAbsent: () => 1);
    final latencies = <double>[];
    final polls = <int>[];
    final big = Uint8List(256 * 256 * 4);
    for (var i = 0; i < _frames; i++) {
      final watch = Stopwatch()..start();
      final frames = [for (final _ in targets) ++_frame];
      final completions = [
        for (final (k, t) in targets.indexed) _draw(t, frames[k], uploads, big),
      ];
      Future<void> complete() => Future.wait(completions).timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          add('timeout');
          return const [];
        },
      );
      Future<void> delay(int ms) =>
          Future<void>.delayed(Duration(milliseconds: ms));
      switch (wait) {
        case _Wait.none || _Wait.poll:
          break;
        case _Wait.complete:
          await complete();
        case _Wait.delay1:
          await delay(1);
        case _Wait.delay4:
          await delay(4);
        case _Wait.delay16:
          await delay(16);
        case _Wait.frame:
          await limit(SchedulerBinding.instance.endOfFrame);
        case _Wait.frame2:
          await limit(SchedulerBinding.instance.endOfFrame);
          await limit(SchedulerBinding.instance.endOfFrame);
        case _Wait.completeFrame:
          await complete();
          await limit(SchedulerBinding.instance.endOfFrame);
        case _Wait.settle:
          await limit(device.settle());
      }
      for (final (k, t) in targets.indexed) {
        var kind = _kind(await limit(device.read(t)), frames[k]);
        var reads = 1;
        while (wait == _Wait.poll && kind != 'behind0' && reads < _polls) {
          kind = _kind(await limit(device.read(t)), frames[k]);
          reads++;
        }
        if (wait == _Wait.poll) polls.add(reads);
        add(kind);
      }
      latencies.add(watch.elapsedMicroseconds / 1000);
    }
    // Lets the backend reuse its uniforms before the next case.
    await limit(device.settle());
    latencies.sort();
    polls.sort();
    return {
      'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
      'device': device.name,
      'wait': wait.name,
      'uploads': uploads,
      'targets': count,
      'reads': _frames * count,
      ...counts,
      if (polls.isNotEmpty) 'p90polls': polls[polls.length * 9 ~/ 10],
      'p50ms': latencies[latencies.length ~/ 2].toStringAsFixed(2),
      'p90ms': latencies[latencies.length * 9 ~/ 10].toStringAsFixed(2),
    };
  }

  // The center pixel as 0xAABBGGRR.
  static int _pixel(Uint8List rgba) {
    final i = (_size ~/ 2 * _size + _size ~/ 2) * 4;
    return rgba[i] | rgba[i + 1] << 8 | rgba[i + 2] << 16 | rgba[i + 3] << 24;
  }
}
