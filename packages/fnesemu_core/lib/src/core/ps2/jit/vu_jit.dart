import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

import '../../../util/jit_adapter.dart';
import '../vu.dart';
import 'vu_context.dart';
import 'vu_translator.dart';

/// Runs the micro programs of VU1 or VU0 compiled by [VuTranslator].
///
/// Data memory is mapped at 0 and micro memory at [microBase]; both, and
/// the registers and ready cycles in the context ([VuCtx]), are the
/// buffers of the [Vu], so the interpreter and compiled code share them.
/// The pipeline state is copied through the context around each compiled
/// run. Compiled code starts only at a pair boundary
/// ([Vu.atPairBoundary]); the interpreter runs the pairs that do not
/// translate. Micro memory changes only through [Vu.writeMicro], outside
/// compiled code, so the code guards of the blocks catch new programs.
///
/// Blocks are keyed by a tag for the contents of micro memory, so that
/// programs which replace each other keep their blocks: after a change,
/// the next run hashes micro memory and takes the tag of that hash.
///
/// The registers of VU0 stay in the context of the EE recompiler for the
/// macro instructions, so a VU0 given to [attach] has its VF, VI and
/// accumulator registers copied to this context and back around each
/// compiled run.
final class VuJit extends JitAdapter implements VuCompiler {
  static const microBase = 0x8000;
  final int _pairs, _dataQuads;

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
      itopHelper: rt.addHelper((a, b, c) => _vu!.itop()),
      vectors: rt.vectors);
  late final _driver = JitDriver(rt,
      translate: (pc, tag) => _translator.translate(pc, tag: tag),
      codeWord: (pc) => micro[pc * 2] | micro[pc * 2 + 1] << 32,
      threshold: compileThreshold);

  VuJit._(super.rt, super.native, int? threshold, this.microBytes,
      this.dataBytes, this._pairs, this._dataQuads)
      : super(compileThreshold: threshold);

  @override
  JitDriver get driver => _driver;

  /// The recompiler of VU [index] on this host, or null when it has none.
  /// It does not reset the shared runtime pool, as the EE recompiler did.
  static VuJit? create(
      {int index = 1, bool native = true, int? compileThreshold}) {
    final pairs = index == 0 ? 512 : 2048;
    final dataQuads = index == 0 ? 256 : 1024;
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
      dataBytes = runtime.alloc(dataQuads * 16);
      microBytes = runtime.alloc(pairs * 8);
    } on StateError {
      runtime.dispose();
      return null;
    }
    runtime.mapPages(0, dataBytes.length, dataBytes);
    runtime.mapPages(microBase, microBytes.length, microBytes, write: false);
    return VuJit._(runtime, native, compileThreshold, microBytes, dataBytes,
        pairs, dataQuads);
  }

  /// a VU1 on the buffers of this recompiler, which runs its programs
  Vu newVu() => _vu =
      Vu(1, micro: micro, data: data, vf: vf, vi: vi, acc: acc, vfReady: ready)
        ..compiler = this;

  /// Runs the programs of [vu], whose memories and ready cycles are the
  /// buffers of this recompiler ([micro], [data] and [ready]) and whose
  /// registers may be elsewhere.
  void attach(Vu vu) {
    _vu = vu..compiler = this;
    _copyRegisters = !identical(vu.vf, vf);
  }

  bool _copyRegisters = false;

  /// the pairs that the last [run] took, for checks
  int lastPairs = 0;

  /// the tags of the latest contents of micro memory by their hashes, the
  /// least recently used first
  static const _tagLimit = 16;
  final _tags = <int, int>{};
  int _tag = 0;
  bool _changed = true;

  @override
  void codeChanged() => _changed = true;

  /// the tag of the current contents of micro memory
  int _currentTag() {
    if (!_changed) return _tag;
    _changed = false;
    var h = 0;
    for (var w = 0; w < micro.length; w++) {
      h = (h * 0x1000193 ^ micro[w]) & 0xffffffffffff;
    }
    var tag = _tags.remove(h);
    if (tag == null) {
      if (_tags.length < _tagLimit) {
        tag = _tags.length;
      } else {
        // the tag used least recently goes to the new contents; the code
        // guards catch its blocks
        tag = _tags.remove(_tags.keys.first)!;
      }
    }
    _tags[h] = tag;
    return _tag = tag;
  }

  @override
  void run(Vu vu, int maxPairs) {
    final ctx = rt.ctx;
    var left = maxPairs;
    lastPairs = 0;
    final tag = _currentTag();
    while (vu.running && left > 0) {
      // A block may take its pairs past the budget, so the last pairs
      // before [maxPairs] are left to the interpreter, which stops at it.
      final budget = left - (VuTranslator.defaultMaxPairs - 1);
      if (budget > 0 &&
          !suspended &&
          vu.atPairBoundary &&
          !_driver.isFallback(vu.pc, tag)) {
        vu.exportPipeline(ctx);
        final copy = _copyRegisters;
        if (copy) {
          vf.setAll(0, vu.vf);
          acc.setAll(0, vu.acc);
          vi.setAll(0, vu.vi);
        }
        final reason = _driver.runBudgeted(vu.pc, tag, budget);
        final spent = _driver.lastClocks;
        if (copy) {
          vu.vf.setAll(0, vf);
          vu.acc.setAll(0, acc);
          vu.vi.setAll(0, vi);
        }
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
