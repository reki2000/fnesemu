import 'dart:typed_data';

import 'package:fnesemu_core/src/core/n64/n64.dart';
import 'package:fnesemu_core/src/core/ps/ps.dart';
import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

import '../../tool/headless/jit_metrics.dart';

void main() {
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
    final n64 = NativeExitStats(rt, core: N64(jit: false));
    data.setUint32(0, 0x12345678);
    expect(n64.opcodeAt(0x1000), 0x12345678);
    n64.record(0x1000, 0x1000, JitReason.user, 20, 3, 0, null);
    data.setUint32(0, 0x87654321);
    n64.record(0x1000, 0x1000, JitReason.user, 20, 4, 0, null);
    final report = n64.report();
    expect(report['count'], 2);
    expect(report['cycles'], 7);
    final sites = report['topSites'] as List;
    expect(sites.map((s) => s['exitOpcode']),
        unorderedEquals([0x12345678, 0x87654321]));
    expect(n64.opcodeAt(0x2000), isNull);
    expect(n64.opcodeAt(0x1ffe), isNull);
    final ps = NativeExitStats(rt, core: Ps(jit: false));
    expect(ps.opcodeAt(0x1000), 0x21436587);
  });
}
