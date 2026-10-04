import 'dart:async';
import 'dart:typed_data';

import 'package:fnesemu/util/uint8list.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/sram.dart';
import '../core/storage_key.dart';
import 'blob_store/blob_store.dart';

class Storage extends Sram {
  static const int saveIntervalSec = 5;

  bool _dirty = false;

  Function(String) onEvent = (String s) {};

  Timer? _worker;

  final BlobStore? _store;

  // sram entries are preloaded so that cores can call init() synchronously
  final Map<String, Uint8List> _cache;

  Storage._(this._store, this._cache) {
    _worker = Timer.periodic(const Duration(seconds: Storage.saveIntervalSec),
        (timer) => saveIfDirty());
  }

  static Future<Storage> open({BlobStore? store}) async {
    try {
      store ??= await BlobStore.open();
      await _migrateSharedPreferences(store);

      final cache = <String, Uint8List>{};
      for (final key in await store.keys()) {
        if (StorageKey.kindOf(key) == StorageKey.sram) {
          final data = await store.get(key);
          if (data != null) cache[key] = data;
        }
      }
      return Storage._(store, cache);
    } catch (e) {
      // run without persistence (e.g. storage is unavailable in the browser)
      return Storage._(null, {});
    }
  }

  // moves sram saved in shared preferences by older versions
  static Future<void> _migrateSharedPreferences(BlobStore store) async {
    final prefs = await SharedPreferences.getInstance();

    for (final oldKey in prefs.getKeys()) {
      final value = prefs.get(oldKey);
      if (value is! String) continue;

      final newKey = switch (oldKey) {
        "psx_mem1" => StorageKey.of("ps", StorageKey.sram, "memcard1"),
        "ss_bram" => StorageKey.of("ss", StorageKey.sram, "bram"),
        _ => StorageKey.of("nes", StorageKey.sram, oldKey),
      };

      await store.put(newKey, Uint8ListEx.fromBase64(value));
      await prefs.remove(oldKey);
    }
  }

  void dispose() {
    saveIfDirty();
    _worker?.cancel();
  }

  reset() {
    id = "";
    _dirty = false;
  }

  @override
  void init(String id, Uint8List initialData) {
    // flush the previous sram before switching
    saveIfDirty();

    final saved = _cache[id];
    if (saved == null) {
      super.init(id, initialData);
      onEvent("loading $id: not found. use initial data");
    } else {
      super.init(id, saved);
      onEvent("successfully loaded $id");
    }
  }

  @override
  void write8(int addr, int value) {
    if (read8(addr) != value) {
      super.write8(addr, value);
      _dirty = true;
    }
  }

  void saveIfDirty() {
    if (id.isNotEmpty && _dirty) {
      save();
      _dirty = false;
    }
  }

  void save() {
    final key = id;
    final bytes = Uint8List.fromList(data);
    _cache[key] = bytes;

    final store = _store;
    if (store == null) {
      return;
    }

    store
        .put(key, bytes)
        .then((_) => onEvent("saved $key size:${bytes.length}"))
        .catchError((e) => onEvent("failed to save $key: $e"));
  }
}
