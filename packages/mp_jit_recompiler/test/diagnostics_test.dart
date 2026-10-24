import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

void main() {
  late JitRuntime rt;
  setUp(() {
    rt = JitRuntime.interpreter(ctxWords: 32, addrMask: 0xffff,
        read: (_, __) => throw StateError('Diagnostics read the bus'),
        write: (_, __, ___) => throw StateError('Diagnostics wrote the bus'));
  });
  tearDown(() => rt.dispose());

  test('instruction inspection honors byte order, aliases and buffer offsets', () {
    final ram = rt.alloc(0x2000);
    rt.mapPages(0, 0x1000, ram, offset: 0x1000);
    ram.setAll(0x1000, [0x12, 0x34, 0x56, 0x78]);
    final big = JitDiagnostics(rt, instructionBytes: 4, byteOrder: Endian.big);
    final little = JitDiagnostics(rt, instructionBytes: 4, byteOrder: Endian.little);
    final half = JitDiagnostics(rt, instructionBytes: 2, byteOrder: Endian.big);
    expect(big.opcodeAt(0), 0x12345678);
    expect(big.opcodeAt(0x10000), 0x12345678);
    expect(little.opcodeAt(0), 0x78563412);
    expect(half.opcodeAt(2), 0x5678);
    expect(big.opcodeAt(2), isNull);
    expect(half.opcodeAt(1), isNull);
    expect(big.opcodeAt(0x1000), isNull);
    expect(big.opcodeAt(0xfff), isNull);
  });

  test('exit classification separates runtime, frontend and mapping causes', () {
    final diagnostics = JitDiagnostics(rt,
        instructionBytes: 4, byteOrder: Endian.little,
        guestExit: (_, reason) => reason == JitReason.user + 9 ? 'custom' : null);
    expect(diagnostics.classify(0, JitReason.budget, 0, null), 'budget');
    expect(diagnostics.classify(0, JitReason.budget, 1, null), 'stopYield');
    expect(diagnostics.classify(0, JitReason.invalid, 0, null), 'codeGuard');
    expect(diagnostics.classify(0, JitReason.miss, 0, null), 'linkMiss');
    expect(diagnostics.classify(0, JitReason.user + 9, 0, null), 'custom');
    expect(diagnostics.classify(0, JitReason.user, 0, 0), 'unmappedOrDevice');
    final ram = rt.alloc(0x1000);
    rt.mapPages(0, ram.length, ram, write: false);
    expect(diagnostics.classify(0, JitReason.user, 0, 0), 'protectedOrReadOnly');
    rt.mapPages(0, ram.length, ram);
    expect(diagnostics.classify(0, JitReason.user, 0, 0), 'memoryExit');
    expect(diagnostics.classify(0, JitReason.user, 0, null), 'guestExit');
  });

  test('return statistics retain totals when bounded site storage fills', () {
    final stats = NativeExitStats(JitDiagnostics(rt,
        instructionBytes: 4, byteOrder: Endian.big));
    for (var i = 0; i < 4097; i++) {
      rt.onNativeExit!(i * 4, 0, JitReason.user, 7, i.isEven ? 3 : 0, 0, null);
    }
    final report = stats.report();
    expect(report['count'], 4097);
    expect(report['cycles'], 2049 * 3);
    expect(report['zeroWork'], 2048);
    expect(report['siteOverflowEntries'], 1);
    expect(stats.sites.length, 4096);
    expect(report['topSites'], hasLength(40));
    rt.nativeEntries = 12;
    stats.clear();
    expect(stats.report()['count'], 0);
    expect(stats.sites, isEmpty);
    expect(rt.nativeEntries, 12);
  });
}
