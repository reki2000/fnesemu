import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

import '../../../util/jit_adapter.dart';
import '../vu.dart';
import 'vu_context.dart';
import 'vu_translator.dart';

/// Runs the micro programs of VU1 compiled by [VuTranslator].
///
/// Data memory is mapped at 0 and micro memory at [microBase]; both, and
/// the registers and ready cycles in the context ([VuCtx]), are the
/// buffers of the [Vu], so the interpreter and compiled code share them.
/// The pipeline state is copied through the context around each compiled
/// run. Compiled code starts only at a pair boundary
/// ([Vu.atPairBoundary]); the interpreter runs the pairs that do not
/// translate. Micro memory is changed only by the VIF, outside compiled
/// code, so the code guards of the blocks catch new programs.
final class VuJit extends JitAdapter implements VuCompiler {
  static const microBase = 0x8000;
  static const _pairs = 2048, _dataQuads = 1024;

  final Uint8List microBytes, dataBytes;
  late final Uint32List micro =
      Uint32List.view(microBytes.buffer, microBytes.offsetInBytes, _pairs * 2);
  late final Uint32List data = Uint32List.view(
      dataBytes.buffer, dataBytes.offsetInBytes, _dataQuads * 4);
  late final Uint32List vf =
      Uint32List.view(rt.ctx.buffer, rt.ctx.offsetInBytes + VuCtx.vf * 4, 128);
  late final Uint32List acc =
      Uint32List.view(rt.ctx.buffer, rt.ctx.offsetInBytes + VuCtx.acc * 4, 4);
  late final Uint16List vi =
      Uint16List.view(rt.ctx.buffer, rt.ctx.offsetInBytes + VuCtx.vi * 4, 16);
  late final Int64List ready = Int64List.view(
      rt.ctx.buffer, rt.ctx.offsetInBytes + VuCtx.ready * 4, 128);

  Vu? _vu;
  late final _translator = VuTranslator(
      pairCount: _pairs,
      dataQuads: _dataQuads,
      microBase: microBase,
      fetch: (word) => micro[word],
      kickHelper: rt.addHelper((a, b, c) {
        _vu!.onXgkick?.call(a);
        return 0;
      }),
      topHelper: rt.addHelper((a, b, c) => _vu!.top()),
      itopHelper: rt.addHelper((a, b, c) => _vu!.itop()));
  late final _driver = JitDriver(rt,
      translate: (pc, tag) => _translator.translate(pc),
      codeWord: (pc) => micro[pc * 2] | micro[pc * 2 + 1] << 32,
      threshold: compileThreshold);

  VuJit._(
      super.rt, super.native, int? threshold, this.microBytes, this.dataBytes)
      : super(compileThreshold: threshold);

  @override
  JitDriver get driver => _driver;

  /// The recompiler of this host, or null when it has none. It does not
  /// reset the shared runtime pool, as the EE recompiler did.
  static VuJit? create({bool native = true, int? compileThreshold}) {
    if (Endian.host != Endian.little) return null;
    int read(int a, int s) => throw StateError('Unmapped compiled read');
    void write(int a, int s, int v) =>
        throw StateError('Unmapped compiled write');
    final runtime = native
        ? JitRuntime.native(
            ctxWords: VuCtx.words, addrMask: 0xffff, read: read, write: write)
        : JitRuntime.interpreter(
            ctxWords: VuCtx.words, addrMask: 0xffff, read: read, write: write);
    if (runtime == null) return null;
    final Uint8List microBytes, dataBytes;
    try {
      dataBytes = runtime.alloc(_dataQuads * 16);
      microBytes = runtime.alloc(_pairs * 8);
    } on StateError {
      runtime.dispose();
      return null;
    }
    runtime.mapPages(0, dataBytes.length, dataBytes);
    runtime.mapPages(microBase, microBytes.length, microBytes, write: false);
    return VuJit._(runtime, native, compileThreshold, microBytes, dataBytes);
  }

  /// a VU1 on the buffers of this recompiler, which runs its programs
  Vu newVu() => _vu =
      Vu(1, micro: micro, data: data, vf: vf, vi: vi, acc: acc, vfReady: ready)
        ..compiler = this;

  /// the pairs that the last [run] took, for checks
  int lastPairs = 0;

  @override
  void run(Vu vu, int maxPairs) {
    final ctx = rt.ctx;
    var left = maxPairs;
    lastPairs = 0;
    while (vu.running && left > 0) {
      // A block may take its pairs past the budget, so the last pairs
      // before [maxPairs] are left to the interpreter, which stops at it.
      final budget = left - (VuTranslator.defaultMaxPairs - 1);
      if (budget > 0 &&
          !suspended &&
          vu.atPairBoundary &&
          !_driver.isFallback(vu.pc, 0)) {
        vu.exportPipeline(ctx);
        final reason = _driver.runBudgeted(vu.pc, 0, budget);
        final spent = _driver.lastClocks;
        vu.importPipeline(ctx, rt.exitPc);
        left -= spent;
        lastPairs += spent;
        if (reason == VuTranslator.reasonEnd) {
          vu.running = false;
          return;
        }
        if (spent > 0) continue;
      }
      vu.step();
      left--;
      lastPairs++;
    }
  }
}
