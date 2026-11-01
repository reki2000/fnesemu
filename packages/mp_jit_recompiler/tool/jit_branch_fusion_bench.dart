import 'dart:convert';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

// This fixture intentionally uses only IR operations available in both
// baseline and optimized revisions. Use identical source and AOT toolchain.
IrBlock _block(String kind) {
  final b = IrBuilder(0x100);
  final current = b.ctxLoad(8);
  final next = b.add(current, b.c32(kind == 'bit' ? 2 : 1));
  b.ctxStore(8, next);
  final limit = b.ctxLoad(9);
  switch (kind) {
    case 'unsigned':
      return b.finish(IrBranch(b.ltU(next, limit), 0x100, 0x200),
          cost: 1);
    case 'signed':
      return b.finish(IrBranch(b.ltS(next, limit), 0x100, 0x200),
          cost: 1);
    case 'bit':
      return b.finish(IrBranch(b.and(next, b.c32(1)), 0x100, 0x200),
          cost: 1);
    case 'exit':
      b.exitIf(b.eq(next, limit),
          const IrExit(JitReason.user, 0x200));
      return b.finish(const IrJump(0x100), cost: 1);
  }
  throw ArgumentError(kind);
}

void _check(bool ok, String message) {
  if (!ok) throw StateError(message);
}

void main(List<String> args) {
  final count = args.isEmpty ? 2000000 : int.parse(args.first);
  if (!JitRuntime.nativeSupported) {
    throw StateError('This benchmark requires a native x64 or ARM64 host');
  }
  for (final kind in ['unsigned', 'signed', 'bit', 'exit']) {
    final runtime = JitRuntime.native(
      ctxWords: 32,
      addrMask: 0xffff,
      read: (_, __) => 0,
      write: (_, __, ___) {},
    )!;
    try {
      final block = _block(kind);
      final compile = Stopwatch()..start();
      final bytes = runtime.installBlock(block);
      compile.stop();
      final samples = <int>[];
      final n = kind == 'bit' ? count : count;
      // Warm up host paths, then run identical work each time.
      for (var i = 0; i < 9; i++) {
        runtime.ctx[8] = kind == 'bit' ? 1 : 0;
        runtime.ctx[9] = n;
        runtime.ctx[JitCtx.budget] = kind == 'bit' ? n : n + 10;
        runtime.ctx[JitCtx.stop] = 0;
        final watch = Stopwatch()..start();
        final reason = runtime.run(0x100, 0);
        watch.stop();
        final wantReason = kind == 'bit'
            ? JitReason.budget
            : kind == 'exit'
                ? JitReason.user
                : JitReason.miss;
        final wantCounter = kind == 'bit' ? 1 + n * 2 : n;
        _check(reason == wantReason,
            '$kind unexpected reason $reason, want $wantReason');
        _check(runtime.ctx[8] == wantCounter,
            '$kind unexpected counter ${runtime.ctx[8]}, want $wantCounter');
        _check(runtime.exitPc == (kind == 'bit' ? 0x100 : 0x200),
            '$kind unexpected exit pc ${runtime.exitPc}');
        if (i >= 2) samples.add(watch.elapsedMicroseconds);
      }
      samples.sort();
      print('BENCH_JSON ${jsonEncode({
        'kind': kind,
        'count': n,
        'native': true,
        'codeBytes': bytes,
        'compileMicros': compile.elapsedMicroseconds,
        'medianMicros': samples[samples.length ~/ 2],
        'minMicros': samples.first,
        'maxMicros': samples.last,
        'samplesMicros': samples,
        'checksum': runtime.ctx[8],
        'entries': runtime.nativeEntries,
      })}');
    } finally {
      runtime.dispose();
    }
  }
}
