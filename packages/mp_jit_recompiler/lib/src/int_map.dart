import 'dart:typed_data';

/// A map from non-negative int keys to non-negative int values, for hot
/// dispatch tables.
///
/// It uses open addressing with linear probing over two typed arrays, so a
/// lookup neither hashes through a generic map nor allocates. [get] returns
/// [absent] for a missing key.
final class IntMap {
  static const absent = -1;

  Int64List _keys;
  Int64List _values;
  int _mask;
  int _shift;
  int _length = 0;

  IntMap([int capacity = 64])
    : _keys = Int64List(_powerOfTwo(capacity))
        ..fillRange(0, _powerOfTwo(capacity), -1),
      _values = Int64List(_powerOfTwo(capacity)),
      _mask = _powerOfTwo(capacity) - 1,
      _shift = 64 - _bits(_powerOfTwo(capacity));

  static int _powerOfTwo(int n) {
    var size = 8;
    while (size < n) {
      size <<= 1;
    }
    return size;
  }

  static int _bits(int size) => size.bitLength - 1;

  int get length => _length;
  bool get isEmpty => _length == 0;
  bool get isNotEmpty => _length != 0;

  @pragma('vm:prefer-inline')
  int _home(int key) => (key * 0x9E3779B97F4A7C15) >>> _shift;

  /// The value of [key], or [absent].
  int get(int key) {
    final keys = _keys, mask = _mask;
    var i = _home(key);
    while (true) {
      final k = keys[i];
      if (k == key) return _values[i];
      if (k == -1) return absent;
      i = (i + 1) & mask;
    }
  }

  bool containsKey(int key) => get(key) != absent;

  void put(int key, int value) {
    if ((_length + 1) * 2 > _keys.length) _grow();
    final keys = _keys, mask = _mask;
    var i = _home(key);
    while (true) {
      final k = keys[i];
      if (k == key) {
        _values[i] = value;
        return;
      }
      if (k == -1) {
        keys[i] = key;
        _values[i] = value;
        _length++;
        return;
      }
      i = (i + 1) & mask;
    }
  }

  /// Removes [key]; true when it was present.
  bool remove(int key) {
    final keys = _keys, values = _values, mask = _mask;
    var i = _home(key);
    while (true) {
      final k = keys[i];
      if (k == -1) return false;
      if (k == key) break;
      i = (i + 1) & mask;
    }
    // shift the following entries of the cluster back over the hole
    var j = i;
    while (true) {
      j = (j + 1) & mask;
      final k = keys[j];
      if (k == -1) break;
      final home = _home(k);
      final stays = i <= j ? i < home && home <= j : i < home || home <= j;
      if (stays) continue;
      keys[i] = k;
      values[i] = values[j];
      i = j;
    }
    keys[i] = -1;
    _length--;
    return true;
  }

  void clear() {
    if (_length == 0) return;
    _keys.fillRange(0, _keys.length, -1);
    _length = 0;
  }

  void _grow() {
    final oldKeys = _keys, oldValues = _values;
    final size = oldKeys.length * 2;
    _keys = Int64List(size)..fillRange(0, size, -1);
    _values = Int64List(size);
    _mask = size - 1;
    _shift = 64 - _bits(size);
    _length = 0;
    for (var i = 0; i < oldKeys.length; i++) {
      if (oldKeys[i] != -1) put(oldKeys[i], oldValues[i]);
    }
  }
}
