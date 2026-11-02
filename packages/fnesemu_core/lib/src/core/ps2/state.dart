import 'dart:typed_data';

import '../../state.dart';

export '../../state.dart';

/// Typed arrays are saved as their raw bytes, in host byte order.
extension Ps2StateWriter on StateWriter {
  void typed(TypedData data) =>
      bytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
}

extension Ps2StateReader on StateReader {
  /// Reads an integer list of exactly [count] values.
  List<int> fields(int count, String what) {
    final v = ints();
    if (v.length != count) throw StateMismatch('$what state layout');
    return v;
  }

  void typed(TypedData data) => bytesInto(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
}
