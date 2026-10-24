import 'dart:async';

import 'benchmark_lock.dart';

/// Absolute frame bounds for one measured batch, with a zero-based index.
final class ComparisonBatch {
  final int index, firstFrame, frames;
  const ComparisonBatch(this.index, this.firstFrame, this.frames);
  int get lastFrame => firstFrame + frames - 1;
}

/// Runs warmup in fixed order, then rotates and reverses measured batches.
/// Callbacks own timing boundaries, input, output comparison and core disposal.
Future<void> runComparison<T>({
  required List<T> variants,
  required int warmupFrames,
  required int frames,
  required int batchFrames,
  required FutureOr<void> Function(T variant, int frame) warmupFrame,
  required FutureOr<void> Function(T variant, ComparisonBatch batch)
      measureBatch,
  FutureOr<void> Function(int frame)? afterWarmupFrame,
  FutureOr<void> Function()? afterWarmup,
  FutureOr<void> Function(ComparisonBatch batch)? afterBatch,
  FutureOr<void> Function()? afterMeasurements,
  String? lockPath = defaultBenchmarkLock,
}) async {
  if (variants.isEmpty ||
      warmupFrames < 0 ||
      frames <= 0 ||
      batchFrames <= 0 ||
      frames % batchFrames != 0) {
    throw ArgumentError(
        'Expected variants, nonnegative warmup and complete positive batches');
  }
  final entries = List<T>.of(variants, growable: false);
  for (var frame = 1; frame <= warmupFrames; frame++) {
    for (final variant in entries) {
      await warmupFrame(variant, frame);
    }
    await afterWarmupFrame?.call(frame);
  }
  await afterWarmup?.call();
  final lock = await acquireBenchmarkLock(lockPath);
  try {
    for (var part = 0; part < frames ~/ batchFrames; part++) {
      final batch = ComparisonBatch(
          part, warmupFrames + part * batchFrames + 1, batchFrames);
      final order = part.isEven ? entries : entries.reversed.toList();
      for (var i = 0; i < entries.length; i++) {
        await measureBatch(order[(i + part ~/ 2) % entries.length], batch);
      }
      await afterBatch?.call(batch);
    }
    await afterMeasurements?.call();
  } finally {
    await releaseBenchmarkLock(lock);
  }
}

/// Returns the first differing index, including a missing trailing element.
int? firstMismatch(List<int> baseline, List<int> variant) {
  final common =
      baseline.length < variant.length ? baseline.length : variant.length;
  for (var i = 0; i < common; i++) {
    if (baseline[i] != variant[i]) return i;
  }
  return baseline.length == variant.length ? null : common;
}

List<Map<String, int?>> differenceBytes(
    int start, List<int> baseline, List<int> variant,
    {int limit = 8}) {
  final result = <Map<String, int?>>[];
  final length =
      baseline.length > variant.length ? baseline.length : variant.length;
  for (var i = 0; i < length && result.length < limit; i++) {
    final a = i < baseline.length ? baseline[i] : null;
    final b = i < variant.length ? variant[i] : null;
    if (a != b) result.add({'address': start + i, 'baseline': a, 'variant': b});
  }
  return result;
}
