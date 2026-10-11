import 'dart:async';

import 'package:fnesemu_core/src/internal/tracer.dart';
import 'package:fnesemu_core/src/trace_flow.dart';
import 'package:fnesemu_core/src/types.dart';
import 'package:test/test.dart';

void main() {
  test('native calls identify return addresses and taken conditions', () {
    expect(trace6502Flow(0x20, 0x8000, operand: 0x9000).returnAddress, 0x8003);
    expect(trace6502Flow(0x22, 0x128000, operand: 0x349000, wide: true).target,
        0x349000);
    expect(
        trace6502Flow(0x44, 0x8000, operand: 0xfe, pce: true).target, 0x8000);
    expect(traceZ80Flow(0xcc, 0x100, 0x80, gb: true).kind, TraceFlowKind.call);
    expect(traceZ80Flow(0xcc, 0x100, 0, gb: true).kind, TraceFlowKind.none);
    expect(traceZ80Flow(0xdc, 0x100, 1).kind, TraceFlowKind.call);
    expect(traceM68kFlow(0x6100, 0x100, extension: 0xfffc).target, 0xfe);
    expect(traceM68kFlow(0x4eb9, 0x100).returnAddress, 0x106);
    expect(traceSh2Flow(0xbffe, 0x100).target, 0x100);
    expect(traceSh2Flow(0x000b, 0x100).delaySlots, 1);
    final registers = List<int>.filled(32, 0)..[14] = 0x200;
    expect(traceMipsFlow(0x0c000080, 0x80000100, registers).target, 0x80000200);
    expect(traceArmFlow(0xeb00003e, 0x100, 0, registers).target, 0x200);
    expect(
        traceArmFlow(0x0b00003e, 0x100, 0, registers).kind, TraceFlowKind.none);
    expect(traceArmFlow(0xf801, 0x102, 32, registers).target, 0x202);
    expect(traceArmFlow(0xe12fff1e, 0x100, 0, registers).kind,
        TraceFlowKind.returned);
    expect(traceArmFlow(0xe25ef004, 0x100, 0, registers).kind,
        TraceFlowKind.interruptReturn);
  });

  test('nested calls, returns and delay slots indent after execution', () {
    final output = <String>[];
    final stream = StreamController<String>(sync: true)
      ..stream.listen(output.add);
    final tracer = Tracer(stream.sink, minSkipThreshold: 100);
    void add(int pc, String name, int next,
            [TraceFlow flow = TraceFlow.none]) =>
        tracer.addTraceLog(TraceLog(pc, 0, name, '', [], flow: flow),
            nextPc: next);
    add(0x100, 'call', 0x200, const TraceFlow.call(0x103, target: 0x200));
    add(0x200, 'delayed call', 0x204,
        const TraceFlow.call(0x208, target: 0x300, delaySlots: 1));
    add(0x204, 'slot', 0x300);
    add(0x300, 'inner', 0x304);
    add(0x304, 'return', 0x308, const TraceFlow.returned(delaySlots: 1));
    add(0x308, 'return slot', 0x208);
    add(0x208, 'outer', 0x103, const TraceFlow.returned());
    add(0x103, 'caller', 0x104);
    expect(output.map((line) => line.substring(0, line.indexOf(' cl:'))), [
      'call ',
      '  delayed call ',
      '  slot ',
      '    inner ',
      '    return ',
      '    return slot ',
      '  outer ',
      'caller '
    ]);
    stream.close();
  });

  test('untracked interrupt returns do not unwind normal calls', () {
    final output = <String>[];
    final stream = StreamController<String>(sync: true)
      ..stream.listen(output.add);
    final tracer = Tracer(stream.sink);
    tracer.addTraceLog(
        const TraceLog(1, 0, 'call', '', [], flow: TraceFlow.call(4)),
        nextPc: 10);
    tracer.addTraceLog(
        const TraceLog(20, 0, 'rti', '', [], flow: TraceFlow.interruptReturn()),
        nextPc: 11);
    tracer.addTraceLog(const TraceLog(11, 0, 'callee', '', []), nextPc: 12);
    expect(output.last, startsWith('  callee'));
    stream.close();
  });

  test('finishing flushes short repeated tails and long suppression counts',
      () {
    for (final count in [2, 8]) {
      final output = <String>[];
      final stream = StreamController<String>(sync: true)
        ..stream.listen(output.add);
      final tracer = Tracer(stream.sink, minSkipThreshold: 3);
      for (var n = 0; n <= count; n++) {
        tracer.addTraceLog(const TraceLog(1, 0, 'loop', '', []));
      }
      tracer.finish();
      expect(output.length, count == 2 ? 3 : 2);
      if (count == 8) expect(output.last, contains('skipped 8'));
      stream.close();
    }
  });
}
