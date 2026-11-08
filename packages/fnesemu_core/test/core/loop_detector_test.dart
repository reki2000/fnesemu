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

}
