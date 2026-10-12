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

  test('reordered history is emitted without suppression', () {
    final pcs = [1, 2, 3, 4, 1, 4, 3, 2];
    final output =
        capture([for (var i = 0; i < pcs.length; i++) instruction(pcs[i], i)]);
    expect(output, hasLength(pcs.length));
    expect(output.where((line) => line.contains('...loop')), isEmpty);
    expect(
        output.map((line) => line.split(' ').first), pcs.map((pc) => 'pc:$pc'));
  });

  test('full cycles are required and partial exit remains visible', () {
    final pcs = [1, 2, 3, 1, 2, 3, 1, 2, 3, 1, 2, 3, 1, 2, 9];
    final output =
        capture([for (var i = 0; i < pcs.length; i++) instruction(pcs[i], i)]);
    expect(accountedLines(output), pcs.length);
    expect(output[3], contains('period:3 iterations:4 tail:2 skipped 9'));
    expect(output[3], contains('cl:0..13 elapsed:13'));
    expect(output.skip(4).map((line) => line.split(' ').first),
        ['pc:1', 'pc:2', 'pc:9']);
  });

  test('exact preserves all state changes; path reports them', () {
    final logs = [for (var i = 0; i < 20; i++) instruction(i % 2, i, state: i)];
    expect(capture(logs), hasLength(logs.length));
    final path = capture(logs, mode: TraceRepeatMode.path);
    expect(accountedLines(path), logs.length);
    expect(path[2], contains('mode:path registers:changed'));
    expect(path.last, contains('skipped 18 lines'));
    expect(path.last, contains('cl:0..19'));
  });

  test('different branch outcomes end suppression before the branch', () {
    final logs = [for (var i = 0; i < 12; i++) instruction(1, i)];
    final output =
        capture(logs, nextPcs: [for (var i = 0; i < 12; i++) i == 11 ? 9 : 1]);
    expect(accountedLines(output), logs.length);
    expect(output[1], contains('iterations:11'));
    expect(output.last, contains('cl:11'));
  });

  test('registers displayed outside structured state are preserved', () {
    final logs = [
      for (var i = 0; i < 12; i++)
        TraceLog(1, i, 'multiply', 'hi:$i lo:${i * 2}', const [0]),
    ];
    expect(capture(logs), hasLength(logs.length));
    final path = capture(logs, mode: TraceRepeatMode.path);
    expect(path[1], contains('registers:changed'));
    expect(path.last, contains('cl:0..11'));
  });

  test('native instruction keys ignore annotations and detect modified code',
      () {
    final logs = [
      for (var i = 0; i < 12; i++)
        TraceLog(1, i, 'load; effective address ${i * 4}', 'r:$i', [i],
            instructionKey: '90620000'),
      const TraceLog(1, 12, 'different load', 'r:12', [12],
          instructionKey: '90620004'),
    ];
    final output = capture(logs, mode: TraceRepeatMode.path);
    expect(accountedLines(output), logs.length);
    expect(output[1], contains('iterations:12'));
    expect(output.last, startsWith('different load'));
    expect(logs.first.withFlow(TraceFlow.none).instructionKey, '90620000');
  });

  test('periods at history limit and longer than old 20-line limit', () {
    for (final period in [1, 21, 64, 256]) {
      final logs = [
        for (var i = 0; i < period * 8; i++) instruction(i % period, i)
      ];
      final output = capture(logs, size: period);
      expect(accountedLines(output), logs.length);
      expect(output.where((s) => s.contains('period:$period ')), hasLength(1));
      expect(output.last, contains('..${logs.length - 1} elapsed:'));
    }
  });

  test('longer periods than configured limit remain visible', () {
    final logs = [for (var i = 0; i < 120; i++) instruction(i % 30, i)];
    expect(capture(logs, size: 20), hasLength(logs.length));
  });

  test('copy closes segments without duplicates or missing lines', () {
    final logs = [for (var i = 0; i < 40; i++) instruction(i % 3, i)];
    final output = capture(logs, copies: {1, 15, 22, 38});
    expect(accountedLines(output), logs.length);
    final cycles = output
        .where((s) => !s.startsWith('...'))
        .map((s) => int.parse(RegExp(r'cl:(\d+)').firstMatch(s)![1]!))
        .toList();
    expect(cycles.toSet(), hasLength(cycles.length));
    expect(cycles, orderedEquals([...cycles]..sort()));
    expect(cycles.last, 39);
  });

  test('exceptions and interrupt returns are never suppressed', () {
    final logs = [
      for (var i = 0; i < 10; i++) instruction(1, i),
      instruction(2, 10, flow: const TraceFlow.exception(1)),
      for (var i = 11; i < 21; i++) instruction(3, i),
      instruction(4, 21, flow: const TraceFlow.interruptReturn()),
    ];
    final output = capture(logs);
    expect(accountedLines(output), logs.length);
    expect(output.where((s) => s.startsWith('pc:2')), hasLength(1));
    expect(output.last, startsWith('pc:4'));
  });

  test('instruction changes and call contexts do not merge', () {
    final logs = [
      for (var i = 0; i < 10; i++) instruction(1, i),
      const TraceLog(1, 10, 'modified instruction', '', [0]),
      instruction(2, 11, flow: const TraceFlow.call(5)),
      for (var i = 12; i < 22; i++) instruction(1, i),
      instruction(3, 22, flow: const TraceFlow.returned()),
      instruction(1, 23),
    ];
    final output = capture(logs, nextPcs: [
      ...List<int?>.filled(11, 1),
      1,
      ...List<int?>.filled(10, 1),
      5,
      2,
    ]);
    expect(accountedLines(output), logs.length);
    expect(output.where((s) => s.startsWith('modified instruction')),
        hasLength(1));
    expect(output.where((s) => s.startsWith('  pc:1')), isNotEmpty);
    expect(output.last, startsWith('pc:1'));
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
