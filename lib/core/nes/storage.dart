import 'dart:developer';
import 'dart:typed_data';

import 'package:fnesemu/util.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Storage {
  SharedPreferences? _prefs;

  static of() {
    final s = Storage();
    SharedPreferences.getInstance().then((prefs) => s._prefs = prefs);
    return s;
  }

  void save(String key, Uint8List data) {
    _prefs?.setString(key, data.toBase64());
    log("saveed $key size:${data.length}");
  }

  Uint8List load(String key) {
    final data = _prefs?.getString(key);
    if (data == null) {
      log("loading $key: not found");
      return Uint8List(0);
    }
    return Uint8ListEx.fromBase64(data);
  }
}
