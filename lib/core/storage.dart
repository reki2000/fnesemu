import 'dart:developer';
import 'dart:typed_data';

import 'package:fnesemu/util.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Storage {
  final SharedPreferences _prefs;
  Storage(SharedPreferences prefs) : _prefs = prefs;

  static of() async {
    final prefs = await SharedPreferences.getInstance();
    return Storage(prefs);
  }

  Future<SharedPreferences> completer = SharedPreferences.getInstance();

  void save(String key, Uint8List data) {
    _prefs.setString(key, data.toBase64());
    log("saveed $key size:${data.length}");
  }

  Uint8List load(String key) {
    final data = _prefs.getString(key);
    if (data == null) {
      log("loading $key: not found");
      return Uint8List(0);
    }
    return Uint8ListEx.fromBase64(data);
  }
}
