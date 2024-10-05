import 'dart:typed_data';

class Storage {
  static of() {
    final s = Storage();
    return s;
  }

  void save(String key, Uint8List data) {}

  Uint8List load(String key) {
    return Uint8List(0);
  }
}
