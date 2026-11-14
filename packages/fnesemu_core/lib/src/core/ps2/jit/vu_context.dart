import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

/// The context words of the VU recompiler, which the interpreter shares.
///
/// The VF registers, the accumulator, the VI registers (two halves per
/// word) and the ready cycles of the VF fields (two words each) are views
/// that the interpreter uses directly. The other words hold the pipeline
/// state, which the interpreter keeps in its own fields and copies around
/// a compiled run ([Vu.exportPipeline], [Vu.importPipeline]).
///
/// The status flag is kept lazily: [status] holds the flag as it was
/// before the MAC results that came out since, and while [statusDirty] is
/// set the flag is [status] with the bits that [mac] and the OR of those
/// results ([macOr]) derive.
///
/// The flag results still in the FMAC pipeline take one slot per pair by
/// age: slot k holds the result of the pair k + 1 pairs before the next
/// one. A slot without a result has the ready cycle [flagNone]. Results of
/// four pairs ago or older are always visible, so they are applied
/// instead of kept.
abstract final class VuCtx {
  static const vf = JitCtx.user;
  static const acc = vf + 128;
  static const vi = acc + 4;
  static const ready = vi + 8;
  static const cycles = ready + 256;
  static const qReady = cycles + 2;
  static const pReady = qReady + 2;
  static const flagReady = pReady + 2;
  static const flagSlots = 3;
  static const q = flagReady + 2 * flagSlots;
  static const qValue = q + 1;
  static const qBusy = qValue + 1;
  static const p = qBusy + 1;
  static const pValue = p + 1;
  static const pBusy = pValue + 1;
  static const r = pBusy + 1;
  static const i = r + 1;
  static const mac = i + 1;
  static const status = mac + 1;
  static const macOr = status + 1;
  static const statusDirty = macOr + 1;
  static const clip = statusDirty + 1;
  static const flagMac = clip + 1;
  static const flagClip = flagMac + flagSlots;
  static const kick = flagClip + flagSlots;
  static const words = kick + 1;

  /// the ready cycle of an empty flag slot, after every real cycle
  static const flagNone = 1 << 62;
}
