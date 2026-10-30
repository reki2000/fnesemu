import 'dart:typed_data';

import 'state.dart';

/// Assembles a quadword from the 32-bit or 64-bit writes the CPU makes to
/// a FIFO window (a 128-bit store arrives as two 64-bit writes).
class QuadFifo {
  final _q = Int64List(2);

  int get low => _q[0];
  int get high => _q[1];

  void saveState(StateWriter w) => w.typed(_q);

  void loadState(StateReader s) => s.typed(_q);

  /// Returns true when the write completed a quadword.
  bool write(int address, int size, int value) {
    if (size == 4) {
      final w = (address >> 2) & 3;
      final shift = (w & 1) * 32;
      final lane = w >> 1;
      _q[lane] =
          (_q[lane] & ~(0xffffffff << shift)) | ((value & 0xffffffff) << shift);
      return w == 3;
    }
    if (size == 8) {
      _q[(address >> 3) & 1] = value;
      return address & 8 != 0;
    }
    return false;
  }
}
