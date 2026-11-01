import 'dart:typed_data';

extension Uint32ListFill on Uint32List {
  /// [fillRange] by doubling block copies, which run as memory moves
  /// instead of one checked store per element.
  void fill(int start, int end, int value) {
    final length = end - start;
    if (length < 16) {
      for (var i = start; i < end; i++) {
        this[i] = value;
      }
      return;
    }
    for (var i = start; i < start + 16; i++) {
      this[i] = value;
    }
    for (var done = 16; done < length; done *= 2) {
      final count = done < length - done ? done : length - done;
      setRange(start + done, start + done + count, this, start);
    }
  }
}
