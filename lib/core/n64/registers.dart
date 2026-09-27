import 'dart:collection';
import 'dart:typed_data';

/// Sign-extended words stay as ints. Full 64-bit values use BigInt on VM/Web.
/// The List interface keeps debugger, boot and test access synchronized.
class N64Registers extends ListBase<BigInt> {
  final _words = Int32List(32);
  final _values = List<BigInt?>.filled(32, null);
  final _wide = List<bool>.filled(32, false);
  final _wordValid = List<bool>.filled(32, true);

  @override
  int get length => 32;
  @override
  set length(int value) => throw UnsupportedError('Fixed N64 register file');

  @override
  BigInt operator [](int index) =>
      _values[index] ??= BigInt.from(_words[index]);

  @override
  void operator []=(int index, BigInt value) {
    if (index == 0) return;
    final full = value.bitLength < 64 ? value : value.toSigned(64);
    final narrow = full.bitLength <= 31;
    if (narrow) {
      _words[index] = full.toInt();
    }
    _values[index] = full;
    _wide[index] = !narrow;
    _wordValid[index] = narrow;
  }

  bool isWord(int index) => !_wide[index];
  int word(int index) {
    if (!_wordValid[index]) {
      _words[index] = _values[index]!.toSigned(32).toInt();
      _wordValid[index] = true;
    }
    return _words[index];
  }

  void setWord(int index, int value) {
    if (index == 0) return;
    _words[index] = value;
    _values[index] = null;
    _wide[index] = false;
    _wordValid[index] = true;
  }
}
