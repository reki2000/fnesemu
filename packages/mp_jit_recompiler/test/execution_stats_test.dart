import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

void main() {
  test('CPU scopes exclude inspection and separate fetches from data requests', () {
    final stats = JitExecutionStats(opcodeAt: (_) => null, regionAt: (_) => 'ram');
    stats.recordMemory(0, 4);
    stats.beginCpuStep();
    stats.recordMemory(0, 4, fetch: true);
    stats.fetching = true;
    stats.recordMemory(0, 4);
    stats.fetching = false;
    stats.recordMemory(4, 2);
    stats.pauseCpuStep();
    stats.recordMemory(8, 4);
    stats.resumeCpuStep();
    stats.recordMemory(8, 1, write: true);
    stats.endCpuStep();
    stats.recordMemory(0, 4);
    expect(stats.report()['memory'], [
      {'kind': 'fetch', 'region': 'ram', 'size': 4, 'count': 1, 'bytes': 4},
      {'kind': 'read', 'region': 'ram', 'size': 2, 'count': 1, 'bytes': 2},
      {'kind': 'write', 'region': 'ram', 'size': 1, 'count': 1, 'bytes': 1},
    ]);
  });

  test('bounded sites retain CPU totals and reset independently', () {
    final stats = JitExecutionStats(opcodeAt: (_) => null,
        regionAt: (a) => '$a', capacity: 1);
    stats.recordCpuStep(0, 9, 2);
    stats.recordCpuStep(4, null, 3);
    stats.recordCpuStep(0, 9, 1);
    stats.recordIdle(7);
    stats.beginCpuStep();
    stats.recordMemory(0, 4);
    stats.recordMemory(1, 4);
    stats.endCpuStep();
    final report = stats.report();
    expect(report['cpuDispatches'], 3);
    expect(report['cpuClocks'], 6);
    expect(report['idleClocks'], 7);
    expect(report['cpuSiteOverflow'], 1);
    expect(report['memorySiteOverflow'], 1);
    expect(report['memoryRequests'], 2);
    expect(report['memoryBytes'], 8);
    expect(report['topCpuSites'], [
      {'pc': 0, 'opcode': 9, 'count': 2, 'clocks': 3}
    ]);
    stats.clear();
    expect(stats.report()['cpuDispatches'], 0);
    expect(stats.report()['memory'], isEmpty);
    expect(stats.report()['topCpuSites'], isEmpty);
    expect(stats.report()['idleClocks'], 0);
    expect(() => JitExecutionStats(opcodeAt: (_) => null,
        regionAt: (_) => '', capacity: 0), throwsArgumentError);
  });

  test('descriptor binds and disables recorders without inspecting the bus', () {
    final rt = JitRuntime.interpreter(ctxWords: 32, addrMask: 0xffff,
        read: (_, __) => throw StateError('Unexpected bus read'),
        write: (_, __, ___) => throw StateError('Unexpected bus write'));
    addTearDown(rt.dispose);
    final diagnostics = JitDiagnostics(rt,
        instructionBytes: 4, byteOrder: Endian.big);
    JitExecutionStats? bound;
    final first = diagnostics.enableExecutionStats();
    diagnostics.bindExecutionStats((stats) => bound = stats);
    expect(bound, same(first));
    expect(first.opcodeAt(0), isNull);
    final second = diagnostics.enableExecutionStats();
    expect(bound, same(second));
    expect(second, isNot(same(first)));
    diagnostics.disableExecutionStats();
    expect(bound, isNull);
    expect(diagnostics.executionStats, isNull);
  });
}
