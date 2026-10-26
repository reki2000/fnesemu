import 'dart:collection';
import 'dart:typed_data';
import '../../util/int.dart';

/// 64-bit general purpose registers. Native and wasm ints are 64-bit and
/// wrap modulo 2^64, so values are stored directly. Writes to r0 are ignored.
/// The List interface keeps debugger, boot and test access synchronized.
/// The two words after the registers hold the multiply/divide results HI and
/// LO, so that compiled code and the interpreter share them with the registers.
class N64Registers extends ListBase<int> {
  /// 32 registers, then HI and LO
  static const storage = 34;
  final Int64List _values;

  N64Registers({Int64List? values}) : _values = values ?? Int64List(storage);

  int get hi => _values[32];
  set hi(int value) => _values[32] = value;
  int get lo => _values[33];
  set lo(int value) => _values[33] = value;

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
  int word(int index) => _values[index].rel32;

  /// stores a 32-bit result sign extended to 64 bits
  void setWord(int index, int value) {
    if (index != 0) _values[index] = value.rel32;
  }
}
