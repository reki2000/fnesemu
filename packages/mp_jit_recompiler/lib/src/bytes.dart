import 'dart:typed_data';

extension BoundedBytesCopy on Uint8List {
  /// Copies [count] bytes of [src] from [srcStart] to [start] in this list.
  ///
  /// The source is limited to the copied range. Shared Wasm RAM would
  /// otherwise materialize the rest of [src] inside `setRange`.
  void setBytes(int start, Uint8List src, int srcStart, int count) {
    setRange(
      start,
      start + count,
      Uint8List.sublistView(src, srcStart, srcStart + count),
    );
  }
}
