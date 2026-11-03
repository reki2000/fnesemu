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

}
