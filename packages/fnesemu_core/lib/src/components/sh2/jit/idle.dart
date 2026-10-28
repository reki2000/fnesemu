import 'dart:typed_data';

import 'jit.dart';

/// Finds a loop that repeats without effect.
///
/// The other devices do not advance while a CPU runs to its target clocks. So
/// a loop is idle when it comes back to the same place with the same registers
/// and without any write: it repeats until the target. The owner then moves
/// the clocks to the target. Registers are compared only for a repeat of the
/// same branch, and the comparison stops at the first difference.
final class Sh2IdleDetector {
  /// the registers r0 to r15, then SR, GBR, VBR, PR, MACH and MACL
  static const words = 22;

  /// r0 to r15 of the CPU
  final Uint32List _regs;

  /// SR, GBR, VBR, PR, MACH and MACL of the CPU
  final Uint32List _state;

  /// the snapshot at the last branch, in the layout of [words]
  final snapshot = Uint32List(words);
  int pc = -1, writes = -1;

  /// Whether a hit leaves the snapshot, so that the next run needs one pass.
  final bool keepSnapshot;

  Sh2IdleDetector(this._regs, this._state, {this.keepSnapshot = false});

  void reset() => pc = writes = -1;

  /// Whether the branch that left [from] and arrived at [at] closes a short
  /// loop. A compiled block can end on its own entry.
  static bool isBackEdge(int at, int from, {required bool compiled}) =>
      (at < from || compiled && at == from) &&
      from - at <= Sh2Jit.idleBranchDistance;

  /// Whether the CPU is back at [at] with the state of the last call and the
  /// same [writeCount]; otherwise keeps the state for the next call.
  bool check(int at, int writeCount) {
    final snap = snapshot;
    var same = at == pc && writeCount == writes;
    if (same) {
      for (var i = 0; i < 16 && same; i++) {
        same = _regs[i] == snap[i];
      }
      for (var i = 0; i < 6 && same; i++) {
        same = _state[i] == snap[16 + i];
      }
    }
    if (same) {
      if (!keepSnapshot) reset();
      return true;
    }
    snap.setRange(0, 16, _regs);
    snap.setRange(16, 22, _state);
    pc = at;
    writes = writeCount;
    return false;
  }
}
