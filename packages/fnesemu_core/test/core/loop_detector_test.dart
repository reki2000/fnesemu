import 'package:fnesemu_core/src/internal/loop_detector.dart';
import 'package:fnesemu_core/src/types.dart';
import 'package:test/test.dart';

TraceStatus sample(int pc, int cycle,
        {int value = 0,
        String context = '',
        int? nextPc,
        String? instructionKey,
        TraceFlow flow = TraceFlow.none}) =>
    TraceStatus(
        TraceLog(pc, cycle, 'pc:$pc', 'r:$value', [value],
            instructionKey: instructionKey,
            flow: flow,
            frame: cycle ~/ 10,
            scanline: cycle % 10),
        context: context,
        nextPc: nextPc);

void main() {
  test('ten unique PCs keep a bounded index without starting a candidate', () {
    final detector = LoopDetector(capacity: 10);
    for (var i = 0; i < 10; i++) {
      final update = detector.add(sample(0x8000 + i * 2, i));
      expect(update.state, LoopState.searching);
      expect(update.ready.single.log.cycle, i);
      expect(update.ended, isNull);
    }
    expect(detector.historyStart, 0);
    expect(detector.historyEnd, 10);
    expect(detector.indexedStates, 10);
    expect(detector.indexedPcs, 10);
    expect(detector.add(sample(0x8000, 10)).state, LoopState.checking);
    for (var i = 1; i < 10; i++) {
      detector.add(sample(0x8000 + i * 2, 10 + i));
    }
    expect(detector.state, LoopState.repeating);
    expect(detector.historyStart, 10);
    expect(detector.historyEnd, 20);
    expect(detector.indexedStates, 0);
    expect(detector.indexedPcs, 0);
    final ended = detector.finish().ended!;
    expect(ended.states, isEmpty);
    expect(ended.statistics.period, 10);
    expect(ended.statistics.iterations, 2);
    expect(ended.statistics.skippedInstructions, 10);
  });

  test('ABC repetitions return only AB from the exit cycle and ready X', () {
    final detector = LoopDetector();
    final pcs = [1, 2, 3, 1, 2, 3, 1, 2, 3, 1, 2, 9];
    final ordinary = <int>[];
    LoopUpdate? exit;
    for (var i = 0; i < pcs.length; i++) {
      final update = detector.add(sample(pcs[i], i));
      ordinary.addAll(update.ready.map((s) => s.log.pc));
      if (update.ended != null) exit = update;
    }
    expect(ordinary, [1, 2, 3, 9]);
    expect(exit!.ready.single.log.pc, 9);
    final ended = exit.ended!;
    expect(ended.states.map((s) => s.log.cycle), [9, 10]);
    expect(ended.statistics.period, 3);
    expect(ended.statistics.iterations, 3);
    expect(ended.statistics.skippedInstructions, 6);
    expect(ended.statistics.partialInstructions, 2);
    expect(ended.statistics.first.log.cycle, 0);
    expect(ended.statistics.last.log.cycle, 10);
    expect(ended.statistics.elapsedClocks, 10);
    expect(() => ended.states.clear(), throwsUnsupportedError);
    expect(() => exit!.ready.clear(), throwsUnsupportedError);
  });

  test('rejected candidates release every pending instruction', () {
    final detector = LoopDetector();
    for (var i = 0; i < 3; i++) {
      detector.add(sample(i + 1, i));
    }
    expect(detector.add(sample(1, 3)).state, LoopState.checking);
    expect(detector.add(sample(2, 4)).ready, isEmpty);
    final rejected = detector.add(sample(9, 5));
    expect(rejected.state, LoopState.searching);
    expect(rejected.ended, isNull);
    expect(rejected.ready.map((s) => s.log.pc), [1, 2, 9]);
  });

  test('PC coincidence must also agree in instruction, context and next PC',
      () {
    final detector = LoopDetector();
    detector.add(sample(1, 0, nextPc: 2, context: 'caller'));
    expect(detector.add(sample(1, 1, nextPc: 3, context: 'caller')).state,
        LoopState.searching);
    expect(detector.add(sample(1, 2, nextPc: 2, context: 'other')).state,
        LoopState.searching);
    expect(
        detector
            .add(sample(1, 3,
                nextPc: 2, context: 'caller', instructionKey: 'modified'))
            .state,
        LoopState.searching);
  });

  test('exact preserves changes and path reports changes in statistics', () {
    for (final mode in TraceRepeatMode.values) {
      final detector = LoopDetector(mode: mode);
      for (var i = 0; i < 20; i++) {
        detector.add(sample(i % 2, i, value: i));
      }
      final update = detector.finish();
      if (mode == TraceRepeatMode.exact) {
        expect(update.ended, isNull);
      } else {
        expect(update.ended!.states, isEmpty);
        expect(update.ended!.statistics.registersChanged, isTrue);
        expect(update.ended!.statistics.skippedInstructions, 18);
      }
    }
  });

  test('expiration removes PC keys and keeps indices monotonic', () {
    final detector = LoopDetector(capacity: 16);
    for (var i = 0; i < 10000; i++) {
      detector.add(sample(i, i));
      expect(detector.retainedStates, lessThanOrEqualTo(16));
      expect(detector.indexedStates, lessThanOrEqualTo(16));
      expect(detector.indexedPcs, lessThanOrEqualTo(16));
    }
    expect(detector.historyStart, 9984);
    expect(detector.historyEnd, 10000);
    expect(detector.add(sample(0, 10000)).state, LoopState.searching);
    detector.reset();
    expect(detector.retainedStates, 0);
    expect(detector.indexedPcs, 0);
    expect(detector.historyStart, 10001);
    detector.add(sample(2, 10001));
    expect(detector.historyEnd, 10002);
  });

  test('confirmed repeats release the index and remain bounded indefinitely',
      () {
    final detector = LoopDetector(capacity: 16, mode: TraceRepeatMode.path);
    for (var i = 0; i < 10000; i++) {
      detector.add(sample(i % 3, i, value: i));
      if (i >= 5) {
        expect(detector.state, LoopState.repeating);
        expect(detector.indexedStates, 0);
        expect(detector.indexedPcs, 0);
        expect(detector.retainedStates, 3);
      }
      expect(detector.retainedStates, lessThanOrEqualTo(16));
    }
    final ended = detector.finish().ended!;
    expect(ended.states.single.log.cycle, 9999);
    expect(ended.statistics.iterations, 3333);
    expect(ended.statistics.skippedInstructions, 9996);
  });

  test('1024 and 2048 periods work at the exact history limit', () {
    for (final period in [1024, 2048]) {
      final detector = LoopDetector(capacity: period);
      for (var i = 0; i < period * 3 + 2; i++) {
        detector.add(sample(i % period, i));
      }
      final ended = detector.finish().ended!;
      expect(ended.statistics.period, period);
      expect(ended.statistics.skippedInstructions, period * 2);
      expect(
          ended.states.map((s) => s.log.cycle), [period * 3, period * 3 + 1]);
    }
  });

  test('candidate limit can miss an old repeat without suppressing its input',
      () {
    for (final limit in [8, 16]) {
      final detector = LoopDetector(capacity: 16, maxCandidates: limit);
      for (var i = 0; i < 10; i++) {
        detector.add(sample(1, i, instructionKey: 'version$i'));
      }
      final update = detector.add(sample(1, 10, instructionKey: 'version0'));
      expect(
          update.state, limit == 8 ? LoopState.searching : LoopState.checking);
      final emitted = [...update.ready, ...detector.finish().ready];
      expect(emitted.single.log.cycle, 10);
    }
  });

  test(
      'finish and reset have distinct output semantics and immutable snapshots',
      () {
    final state = [0];
    final snapshot = TraceStatus(TraceLog(1, 0, 'one', 'r:0', state));
    state[0] = 10;
    expect(snapshot.log.state, [0]);
    expect(() => snapshot.log.state[0] = 9, throwsUnsupportedError);
    final detector = LoopDetector();
    detector.add(sample(1, 0));
    detector.add(sample(2, 1));
    detector.add(sample(1, 2));
    final pending = detector.finish();
    expect(pending.ready.single.log.cycle, 2);
    expect(detector.finish().ready, isEmpty);
    detector.add(sample(1, 3));
    detector.add(sample(2, 4));
    detector.add(sample(1, 5));
    detector.reset();
    expect(detector.finish().ready, isEmpty);
    expect(pending.ready.single.log.cycle, 2);
  });

  test('exceptions close the repeat and are ordinary output', () {
    final detector = LoopDetector();
    for (var i = 0; i < 7; i++) {
      detector.add(sample(i % 3, i));
    }
    final update =
        detector.add(sample(9, 7, flow: const TraceFlow.exception(3)));
    expect(update.ended!.states.single.log.cycle, 6);
    expect(update.ready.single.log.pc, 9);
    expect(detector.retainedStates, 0);
    expect(detector.historyEnd, 8);
  });
}
