import 'dart:io';

import 'package:test/test.dart';

import '../../tool/headless/benchmark_lock.dart';
import '../../tool/headless/comparison.dart';

void main() {
  test('warmup and rotated batches retain absolute intervals and boundaries',
      () async {
    final events = <String>[];
    await runComparison(
      variants: ['a', 'b', 'c'],
      warmupFrames: 2,
      frames: 8,
      batchFrames: 2,
      lockPath: null,
      warmupFrame: (v, f) => events.add('warm $v $f'),
      afterWarmupFrame: (f) => events.add('warm check $f'),
      afterWarmup: () => events.add('ready'),
      measureBatch: (v, b) async {
        events.add('$v ${b.index} ${b.firstFrame} ${b.lastFrame}');
        await Future<void>.value();
        events.add('done $v');
      },
      afterBatch: (b) => events.add('check ${b.index}'),
      afterMeasurements: () => events.add('complete'),
    );
    expect(events, [
      'warm a 1',
      'warm b 1',
      'warm c 1',
      'warm check 1',
      'warm a 2',
      'warm b 2',
      'warm c 2',
      'warm check 2',
      'ready',
      'a 0 3 4',
      'done a',
      'b 0 3 4',
      'done b',
      'c 0 3 4',
      'done c',
      'check 0',
      'c 1 5 6',
      'done c',
      'b 1 5 6',
      'done b',
      'a 1 5 6',
      'done a',
      'check 1',
      'b 2 7 8',
      'done b',
      'c 2 7 8',
      'done c',
      'a 2 7 8',
      'done a',
      'check 2',
      'b 3 9 10',
      'done b',
      'a 3 9 10',
      'done a',
      'c 3 9 10',
      'done c',
      'check 3',
      'complete',
    ]);
  });

  test('invalid plans fail before running a core', () async {
    for (final (warm, frames, batch, variants) in [
      (-1, 2, 1, ['a']),
      (0, 0, 1, ['a']),
      (0, 2, 0, ['a']),
      (0, 3, 2, ['a']),
      (0, 2, 1, <String>[]),
    ]) {
      await expectLater(
          runComparison(
              variants: variants,
              warmupFrames: warm,
              frames: frames,
              batchFrames: batch,
              lockPath: null,
              warmupFrame: (_, __) => fail('Unexpected warmup'),
              measureBatch: (_, __) => fail('Unexpected measurement')),
          throwsArgumentError);
    }
  });

  test('output comparison detects trailing bytes and bounds detail storage',
      () {
    expect(firstMismatch([1, 2], [1, 2]), isNull);
    expect(firstMismatch([1, 2], [1, 3]), 1);
    expect(firstMismatch([1], [1, 2]), 1);
    expect(firstMismatch([1, 2], [1]), 1);
    expect(differenceBytes(0x100, [1, 2, 3], [1, 4], limit: 1), [
      {'address': 0x101, 'baseline': 2, 'variant': 4}
    ]);
    expect(differenceBytes(0, [1], [1, 2]), [
      {'address': 1, 'baseline': null, 'variant': 2}
    ]);
  });

  test('comparison lock covers final checks and releases on callback failure',
      () async {
    final dir = Directory.systemTemp.createTempSync('comparison-lock-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/bench.lock';
    Future<int> contender() async =>
        (await Process.run('flock', ['-n', path, 'true'])).exitCode;
    for (final failAt in ['batch', 'check', 'complete', 'none']) {
      Future<void> run() => runComparison(
          variants: ['a'],
          warmupFrames: 0,
          frames: 1,
          batchFrames: 1,
          lockPath: path,
          warmupFrame: (_, __) => fail('Unexpected warmup'),
          afterWarmup: () async => expect(await contender(), 0),
          measureBatch: (_, __) async {
            expect(await contender(), 1);
            if (failAt == 'batch') throw StateError('batch');
          },
          afterBatch: (_) {
            if (failAt == 'check') throw StateError('check');
          },
          afterMeasurements: () async {
            expect(await contender(), 1);
            if (failAt == 'complete') throw StateError('complete');
          });
      if (failAt == 'none') {
        await run();
      } else {
        await expectLater(run(), throwsStateError);
      }
      expect(await contender(), 0);
    }
  }, testOn: 'vm && linux');

  test('external synchronization signals readiness without acquiring flock',
      () async {
    final dir = Directory.systemTemp.createTempSync('comparison-sync-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final pending = acquireBenchmarkLock(null, syncDir: dir.path);
    expect(File('${dir.path}/ready.$pid').existsSync(), isTrue);
    File('${dir.path}/go').writeAsStringSync('');
    expect(await pending, isNull);
    await releaseBenchmarkLock(null);
  }, testOn: 'vm');
}
