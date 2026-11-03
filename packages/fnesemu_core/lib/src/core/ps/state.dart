import 'dart:collection';
import 'dart:typed_data';

import '../../state.dart';

export '../../state.dart';

/// Typed arrays are saved as their raw bytes, in host byte order.
extension PsStateWriter on StateWriter {
  void typed(TypedData data) =>
      bytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));

  void queue(Queue<int> values) => ints(values.toList());
}

extension PsStateReader on StateReader {
  /// Reads an integer list of exactly [count] values.
  List<int> fields(int count, String what) {
    final v = ints();
    if (v.length != count) throw StateMismatch('$what state layout');
    return v;
  }

  void typed(TypedData data) => bytesInto(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));

  void queueInto(Queue<int> values) {
    final v = ints();
    values
      ..clear()
      ..addAll(v);
  }
}
