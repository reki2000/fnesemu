import 'dart:typed_data';

import 'package:fnesemu_core/src/core.dart';
import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

import '../../tool/headless/jit_metrics.dart';

class _DiagnosticCore extends Core {
  final JitDiagnostics diagnostics;
  _DiagnosticCore(this.diagnostics);
  int cpu = 0, compiled = 0;
  @override
  int get cpuClocks => cpu;
  @override
  int get jitClocks => compiled;
  @override
  Iterable<JitDiagnostics> get jitDiagnostics => [diagnostics];
}

void main() {
  test('interval counters consume diagnostics without a concrete core type',
      () {
    final rt = JitRuntime.interpreter(
        ctxWords: 16,
        addrMask: 0xffff,
        read: (_, __) => 0,
        write: (_, __, ___) {});
    addTearDown(rt.dispose);
    final core = _DiagnosticCore(
        JitDiagnostics(rt, instructionBytes: 4, byteOrder: Endian.little));
    core.cpu = 100;
    core.compiled = 30;
    rt.nativeEntries = 8;
    final start = JitCounters(core);
    core.cpu += 20;
    core.compiled += 5;
    rt.nativeEntries += 2;
    expect(JitCounters(core).since(start), {
      'cpuClocks': 20,
      'jitClocks': 5,
      'jitCyclePercent': 25.0,
      'nativeEntries': 2,
      'meanNativeExitCycles': 2.5,
    });
  });

  test('exit diagnostics separate opcode changes without reading devices', () {
    final rt = JitRuntime.interpreter(
        ctxWords: 16,
        addrMask: 0xffff,
        read: (_, __) => throw StateError('Diagnostic device read'),
        write: (_, __, ___) {});
    addTearDown(rt.dispose);
    final bytes = rt.alloc(4096);
    rt.mapPages(0x1000, bytes.length, bytes);
    final data = ByteData.sublistView(bytes);
    final n64 = NativeExitStats(
        JitDiagnostics(rt, instructionBytes: 4, byteOrder: Endian.big));
    data.setUint32(0, 0x12345678);
    expect(n64.diagnostics.opcodeAt(0x1000), 0x12345678);
    n64.record(0x1000, 0x1000, JitReason.user, 20, 3, 0, null);
    data.setUint32(0, 0x87654321);
    n64.record(0x1000, 0x1000, JitReason.user, 20, 4, 0, null);
    final report = n64.report();
    expect(report['count'], 2);
    expect(report['cycles'], 7);
    final sites = report['topSites'] as List;
    expect(sites.map((s) => s['exitOpcode']),
        unorderedEquals([0x12345678, 0x87654321]));
    expect(n64.diagnostics.opcodeAt(0x2000), isNull);
    expect(n64.diagnostics.opcodeAt(0x1ffe), isNull);
    final ps = NativeExitStats(
        JitDiagnostics(rt, instructionBytes: 4, byteOrder: Endian.little));
    expect(ps.diagnostics.opcodeAt(0x1000), 0x21436587);
  });
}
