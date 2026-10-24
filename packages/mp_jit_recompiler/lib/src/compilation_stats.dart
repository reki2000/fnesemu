import 'ir.dart';

/// Optional interval telemetry for translation, publication and cache lifecycle.
/// Host lookup counters exclude links followed entirely inside compiled code.
final class JitCompilationStats {
  final int capacity;
  int translationAttempts = 0, translationRejected = 0, translationErrors = 0;
  int translationMicros = 0,
      installAttempts = 0,
      installs = 0,
      installErrors = 0;
  int installMicros = 0, generatedBytes = 0;
  int driverCacheHits = 0, driverCacheMisses = 0, fallbackCacheHits = 0;
  int guardFailures = 0, invalidations = 0, cacheClears = 0, evictedBlocks = 0;
  int dispatchProfileClears = 0, repeatInstallsAtRetainedSites = 0;
  int suppressedSiteEvents = 0;
  final _sites = <(int, int), _CompilationSite>{};

  JitCompilationStats({this.capacity = 4096}) {
    if (capacity <= 0) throw ArgumentError.value(capacity, 'capacity');
  }

  _CompilationSite? _site(int pc, int tag) {
    final key = (pc, tag), existing = _sites[(pc, tag)];
    if (existing != null) return existing;
    if (_sites.length >= capacity) {
      suppressedSiteEvents++;
      return null;
    }
    return _sites[key] = _CompilationSite();
  }

  IrBlock? measureTranslation(int pc, int tag, IrBlock? Function() translate) {
    translationAttempts++;
    final site = _site(pc, tag);
    if (site != null) site.translations++;
    final timer = Stopwatch()..start();
    try {
      final block = translate();
      timer.stop();
      if (block == null) translationRejected++;
      return block;
    } catch (_) {
      timer.stop();
      translationErrors++;
      rethrow;
    } finally {
      final micros = timer.elapsedMicroseconds;
      translationMicros += micros;
      if (site != null) site.translationMicros += micros;
    }
  }

  void measureInstallation(IrBlock block, int Function() install) {
    installAttempts++;
    final site = _site(block.pc, block.tag);
    final timer = Stopwatch()..start();
    try {
      final bytes = install();
      timer.stop();
      installs++;
      generatedBytes += bytes;
      if (site != null) {
        if (site.installs > 0) repeatInstallsAtRetainedSites++;
        site.installs++;
        site.generatedBytes += bytes;
      }
    } catch (_) {
      timer.stop();
      installErrors++;
      rethrow;
    } finally {
      final micros = timer.elapsedMicroseconds;
      installMicros += micros;
      if (site != null) site.installMicros += micros;
    }
  }

  void recordLookup(bool hit) {
    if (hit) {
      driverCacheHits++;
    } else {
      driverCacheMisses++;
    }
  }

  void recordInvalidation(int pc, int tag) {
    invalidations++;
    final site = _site(pc, tag);
    if (site != null) site.invalidations++;
  }

  void recordCacheClear(int blocks) {
    cacheClears++;
    evictedBlocks += blocks;
  }

  /// Resets the interval without changing installed code or driver policy.
  void clear() {
    translationAttempts = translationRejected = translationErrors = 0;
    translationMicros = installAttempts = installs = installErrors = 0;
    installMicros = generatedBytes = 0;
    driverCacheHits = driverCacheMisses = fallbackCacheHits = 0;
    guardFailures = invalidations = cacheClears = evictedBlocks = 0;
    dispatchProfileClears = repeatInstallsAtRetainedSites = 0;
    suppressedSiteEvents = 0;
    _sites.clear();
  }

  Map<String, Object?> report() {
    final ranked = _sites.entries.toList()
      ..sort(
        (a, b) => (b.value.translationMicros + b.value.installMicros).compareTo(
          a.value.translationMicros + a.value.installMicros,
        ),
      );
    return {
      'translationAttempts': translationAttempts,
      'translationRejected': translationRejected,
      'translationErrors': translationErrors,
      'translationMicros': translationMicros,
      'installAttempts': installAttempts,
      'installs': installs,
      'installErrors': installErrors,
      'installMicros': installMicros,
      'generatedBytes': generatedBytes,
      'generatedBytesScope': 'publishedBlockPayloads',
      'driverCacheHits': driverCacheHits,
      'driverCacheMisses': driverCacheMisses,
      'fallbackCacheHits': fallbackCacheHits,
      'guardFailures': guardFailures,
      'invalidations': invalidations,
      'cacheClears': cacheClears,
      'evictedBlocks': evictedBlocks,
      'dispatchProfileClears': dispatchProfileClears,
      'repeatInstallsAtRetainedSites': repeatInstallsAtRetainedSites,
      'suppressedSiteEvents': suppressedSiteEvents,
      'topSites': [
        for (final e in ranked.take(40))
          {
            'pc': e.key.$1,
            'tag': e.key.$2,
            'translations': e.value.translations,
            'translationMicros': e.value.translationMicros,
            'installs': e.value.installs,
            'installMicros': e.value.installMicros,
            'generatedBytes': e.value.generatedBytes,
            'invalidations': e.value.invalidations,
          },
      ],
    };
  }
}

final class _CompilationSite {
  int translations = 0, translationMicros = 0, installs = 0;
  int installMicros = 0, generatedBytes = 0, invalidations = 0;
}
