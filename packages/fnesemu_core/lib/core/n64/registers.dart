import 'dart:collection';
import 'dart:typed_data';

/// 64-bit general purpose registers. Native and wasm ints are 64-bit and
/// wrap modulo 2^64, so values are stored directly. Writes to r0 are ignored.
/// The List interface keeps debugger, boot and test access synchronized.
class N64Registers extends ListBase<int> {
  final _values = Int64List(32);

  @override
  int get length => 32;
  @override
  set length(int value) => throw UnsupportedError('Fixed N64 register file');

  @override
  int operator [](int index) => _values[index];

  @override
  void operator []=(int index, int value) {
    if (index != 0) _values[index] = value;
  }

  /// low 32 bits, sign extended
  int word(int index) => _values[index].toSigned(32);

  /// stores a 32-bit result sign extended to 64 bits
  void setWord(int index, int value) {
    if (index != 0) _values[index] = value.toSigned(32);
  }
}
