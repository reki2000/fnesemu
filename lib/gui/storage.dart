import 'dart:async';
import 'dart:typed_data';

import 'package:fnesemu/util/uint8list.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/sram.dart';

class Storage extends Sram {
  bool _dirty = false;

  Function(String) _onEvent = (String s) {};

  Timer? _worker;

  SharedPreferences? _prefs;

  static of({Function(String)? onEvent}) {
    final s = Storage();

    if (onEvent != null) {
      s._onEvent = onEvent;
    }

    SharedPreferences.getInstance().then((prefs) => s._prefs = prefs);

    s._worker?.cancel();
    s._worker =
        Timer.periodic(const Duration(seconds: 2), (timer) => s.saveIfDirty());

    return s;
  }

  reset() {
    id = "";
    _dirty = false;
  }

  @override
  void init(String id, Uint8List initialData) {
    final saved = _prefs?.getString(id);
    if (saved == null) {
      super.init(id, initialData);
      _onEvent("loading $id: not found. use initial data");
    } else {
      super.init(id, Uint8ListEx.fromBase64(saved));
      _onEvent("successfully loaded $id");
    }
  }

  @override
  void write8(int addr, int value) {
    super.write8(addr, value);
    _dirty = true;
  }

  void saveIfDirty() {
    if (id.isNotEmpty && _dirty) {
      save();
      _dirty = false;
    }
  }

  void save() {
    _prefs?.setString(id, Uint8List.fromList(data).toBase64());
    _onEvent("saved $id size:${data.length}");
  }
}
