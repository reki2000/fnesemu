import 'dart:developer';
import 'dart:typed_data';

class Storage {
  final Map<String, Uint8List> _storage = {};

  void save(String key, Uint8List data) {
    _storage[key] = data;
    log("saveed $key size:${data.length}");
  }

  Uint8List load(String key) {
    log("loaded $key");
    return _storage[key] ?? Uint8List(0);
  }
}
