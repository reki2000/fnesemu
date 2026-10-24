import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

JitRuntime reference() => JitRuntime.interpreter(
  ctxWords: 32,
  addrMask: 0xffff,
  read: (_, __) => 0,
  write: (_, __, ___) {},
);
IrBlock block(int pc, {int tag = 0}) {
  final b = IrBuilder(pc, tag: tag);
  b.ctxStore(8, b.add(b.ctxLoad(8), b.c32(1)));
  return b.finish(IrExitTerm(IrExit(JitReason.user, pc + 4)), cost: 1);
}

void main() {
  test(
    'bounded sites preserve totals and distinguish rejected/failed work',
    () {
      final stats = JitCompilationStats(capacity: 1);
      expect(stats.measureTranslation(0, 0, () => null), isNull);
      expect(
        () =>
            stats.measureTranslation(0, 0, () => throw StateError('translate')),
        throwsStateError,
      );
      stats.measureTranslation(0, 0, () => block(0));
      stats.measureInstallation(block(0), () => 12);
      stats.measureInstallation(block(0), () => 16);
      stats.measureInstallation(block(4), () => 20);
      expect(
        () => stats.measureInstallation(
          block(4),
          () => throw StateError('publish'),
        ),
        throwsStateError,
      );
      final report = stats.report();
      expect(report['translationAttempts'], 3);
      expect(report['translationRejected'], 1);
      expect(report['translationErrors'], 1);
      expect(report['installAttempts'], 4);
      expect(report['installErrors'], 1);
      expect(report['installs'], 3);
      expect(report['generatedBytes'], 48);
      expect(report['repeatInstallsAtRetainedSites'], 1);
      expect(report['suppressedSiteEvents'], 2);
      expect(report['topSites'], hasLength(1));
      expect(report['translationMicros'], greaterThanOrEqualTo(0));
      expect(report['installMicros'], greaterThanOrEqualTo(0));
      stats.clear();
      expect(stats.report()['installs'], 0);
      expect(stats.report()['topSites'], isEmpty);
      expect(stats.report()['suppressedSiteEvents'], 0);
      expect(() => JitCompilationStats(capacity: 0), throwsArgumentError);
    },
  );

  for (final compiled in [false, true]) {
    test(
      '${compiled ? 'compiled' : 'reference'} publication and invalidation telemetry preserves code',
      () {
        final rt = compiled
            ? JitRuntime.native(
                ctxWords: 32,
                addrMask: 0xffff,
                read: (_, __) => 0,
                write: (_, __, ___) {},
              )!
            : reference();
        addTearDown(rt.dispose);
        final diagnostics = JitDiagnostics(
          rt,
          instructionBytes: 4,
          byteOrder: Endian.big,
        );
        final b = block(0x100, tag: 7);
        rt.install(b);
        final stats = diagnostics.enableCompilationStats();
        expect(rt.contains(0x100, 7), isTrue);
        expect(stats.installs, 0);
        for (var i = 0; i < 2; i++) {
          rt.install(b);
          rt.ctx[JitCtx.budget] = 10;
          expect(rt.run(0x100, 7), JitReason.user);
        }
        expect(rt.ctx[8], 2);
        expect(stats.installs, 2);
        expect(stats.generatedBytes, compiled ? greaterThan(0) : 0);
        expect(stats.repeatInstallsAtRetainedSites, 1);
        rt.invalidate(0x100, 0);
        expect(stats.invalidations, 0);
        rt.invalidate(0x100, 7);
        rt.invalidate(0x100, 7);
        expect(stats.invalidations, 1);
        rt.install(b);
        rt.clear();
        expect(stats.cacheClears, 1);
        expect(stats.evictedBlocks, 1);
        rt.install(b);
        stats.clear();
        expect(rt.contains(0x100, 7), isTrue);
        expect(stats.installs, 0);
        final invalidBuilder = IrBuilder(0x200);
        invalidBuilder.ctxStore(1000, invalidBuilder.c32(1));
        final invalid = invalidBuilder.finish(
          const IrExitTerm(IrExit(JitReason.user, 0x204)),
          cost: 1,
        );
        expect(() => rt.install(invalid), throwsStateError);
        expect(stats.installErrors, 1);
        expect(stats.installs, 0);
        diagnostics.disableCompilationStats();
        rt.install(b);
        rt.clear();
        expect(stats.installs, 0);
        expect(stats.cacheClears, 0);
      },
      skip: compiled && !JitRuntime.nativeSupported,
    );
  }

  test(
    'driver records entry lookups, translation and retained recompilation',
    () {
      final rt = reference();
      addTearDown(rt.dispose);
      final ram = rt.alloc(4096);
      rt.mapPages(0x1000, ram.length, ram);
      var word = 0;
      final stats = rt.compilationStats = JitCompilationStats();
      final driver = JitDriver(
        rt,
        threshold: 1,
        prepareFirst: true,
        codeWord: (_) => word,
        translate: (pc, tag) {
          final b = IrBuilder(pc, tag: tag)..guard(0x1000, word);
          b.ctxStore(8, b.add(b.ctxLoad(8), b.c32(1)));
          return b.finish(IrExitTerm(IrExit(JitReason.user, pc + 4)), cost: 1);
        },
      );
      expect(driver.runBudgeted(0x100, 0, 10), JitReason.user);
      expect(driver.runBudgeted(0x100, 0, 10), JitReason.user);
      word = 1;
      ram[0] = 1;
      expect(driver.runBudgeted(0x100, 0, 10), JitReason.user);
      expect(rt.ctx[8], 3);
      expect(stats.driverCacheMisses, 2);
      expect(stats.driverCacheHits, 2);
      expect(stats.translationAttempts, 2);
      expect(stats.installs, 2);
      expect(stats.guardFailures, 1);
      expect(stats.invalidations, 1);
      expect(stats.repeatInstallsAtRetainedSites, 1);
      driver.reset();
      expect(stats.cacheClears, 1);
      expect(stats.evictedBlocks, 1);
      expect(stats.dispatchProfileClears, 1);
      expect(rt.ctx[8], 3);
      expect(driver.executedClocks, 0);
    },
  );

  test('guard observations retain adapter exit and invalidation policy', () {
    final rt = reference();
    addTearDown(rt.dispose);
    final ram = rt.alloc(4096);
    rt.mapPages(0x1000, ram.length, ram);
    final b = IrBuilder(0x100)..guard(0x1000, 0);
    rt.install(b.finish(const IrExitTerm(IrExit(JitReason.user, 0x104)), cost: 1));
    ram[0] = 1;
    final stats = rt.compilationStats = JitCompilationStats();
    final driver = JitDriver(rt, translate: (_, __) => null,
        codeWord: (_) => 1, continueAfterExit: (_) => false);
    expect(driver.runBudgeted(0x100, 0, 10), JitReason.invalid);
    expect(stats.guardFailures, 1);
    expect(stats.invalidations, 0);
    expect(rt.contains(0x100, 0), isTrue);
  });

  test('fallback cache and capacity clears retain existing policy hooks', () {
    final rt = reference();
    addTearDown(rt.dispose);
    final stats = rt.compilationStats = JitCompilationStats();
    final installed = <int>[];
    var clears = 0;
    final driver =
        JitDriver(
            rt,
            threshold: 1,
            capacity: 1,
            codeWord: (_) => 0,
            translate: (pc, _) => pc == 0 ? null : block(pc),
          )
          ..onInstall = (b) {
            installed.add(b.pc);
          }
          ..onClear = () => clears++;
    driver.runBudgeted(0, 0, 10);
    expect(driver.isFallback(0, 0), isTrue);
    driver.runBudgeted(0, 0, 10);
    expect(stats.fallbackCacheHits, 2);
    expect(stats.translationRejected, 1);
    driver.runBudgeted(4, 0, 10);
    expect(stats.dispatchProfileClears, 1);
    expect(clears, 1);
    expect(stats.cacheClears, 0);
    expect(installed, [4]);
  });
}
