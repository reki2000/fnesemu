import 'dart:async';
import 'dart:math';

import 'package:fnesemu_core/src/internal/tracer.dart';
import 'package:fnesemu_core/src/types.dart';
import 'package:test/test.dart';

List<String> capture(List<TraceLog> logs,
    {TraceRepeatMode mode = TraceRepeatMode.exact,
    int size = 256,
    List<int?>? nextPcs,
    Set<int> copies = const {}}) {
  final output = <String>[];
  final stream = StreamController<String>(sync: true)
    ..stream.listen(output.add);
  final tracer = Tracer(stream.sink, mode: mode, size: size);
  for (var i = 0; i < logs.length; i++) {
    tracer.addTraceLog(logs[i], nextPc: nextPcs?[i]);
    if (copies.contains(i)) {
      tracer.finish();
      tracer.finish();
    }
  }
  tracer.finish();
  stream.close();
  return output;
}

TraceLog instruction(int pc, int cycle,
        {int state = 0, TraceFlow flow = TraceFlow.none}) =>
    TraceLog(pc, cycle, 'pc:$pc', 'r:$state', [state],
        frame: cycle ~/ 100, scanline: cycle % 100, flow: flow);

int accountedLines(List<String> output) => output.fold(0, (count, line) {
      final skip = RegExp(r'skipped (\d+) lines').firstMatch(line);
      return count + (skip == null ? 1 : int.parse(skip[1]!));
    });

void main() {
  test('register dumps form one line with a single metadata suffix', () {
    final output = capture([
      const TraceLog(1, 1234, '0001: ea NOP   ', ' A:00\n X:01\tY:02 ', []),
    ]);
    expect(output.single, '0001: ea NOP A:00 X:01 Y:02 cl:1,234 f:0 s:0\n');
  });

  test('mixed random traces preserve count, order and final state', () {
    final random = Random(42);
    for (final mode in TraceRepeatMode.values) {
      for (var run = 0; run < 30; run++) {
        final pcs = <int>[];
        for (var block = 0; block < 30; block++) {
          final body =
              List.generate(1 + random.nextInt(12), (_) => random.nextInt(8));
          for (var n = random.nextInt(10); n >= 0; n--) {
            pcs.addAll(body);
          }
        }
        final logs = [
          for (var i = 0; i < pcs.length; i++)
            instruction(pcs[i], i, state: i ~/ 100)
        ];
        final output = capture(logs, mode: mode, size: 16);
        expect(accountedLines(output), logs.length);
        var previous = -1;
        for (final line in output) {
          if (line.startsWith('...')) {
            final period =
                int.parse(RegExp(r'period:(\d+)').firstMatch(line)![1]!);
            final skipped =
                int.parse(RegExp(r'skipped (\d+) lines').firstMatch(line)![1]!);
            for (var i = previous + 1; i <= previous + skipped; i++) {
              expect(logs[i].pc, logs[i - period].pc);
              if (mode == TraceRepeatMode.exact) {
                expect(logs[i].state, logs[i - period].state);
              }
            }
            previous += skipped;
            continue;
          }
          final cycle = int.parse(
              RegExp(r'cl:([\d,]+)').firstMatch(line)![1]!.replaceAll(',', ''));
          expect(cycle, previous + 1);
          expect(line, startsWith('pc:${pcs[cycle]} '));
          previous = cycle;
        }
        expect(previous, logs.length - 1);
      }
    }
  });
}
