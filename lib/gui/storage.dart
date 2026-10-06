import 'dart:async';
import 'dart:convert';
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

  // application settings, preloaded as well
  final Map<String, String> _settings;

  // keys of the BIOS files. the data is read when a core is created
  final Set<String> _biosKeys;

  // BIOS files kept on memory when the persistent store is unavailable
  final Map<String, Uint8List> _biosData = {};

  Storage._(this._store, this._cache, this._settings, this._biosKeys) {
    _worker = Timer.periodic(const Duration(seconds: Storage.saveIntervalSec),
        (timer) => saveIfDirty());
  }

  static Future<Storage> open({BlobStore? store}) async {
    try {
      store ??= await BlobStore.open();
      await _migrateSharedPreferences(store);

      final cache = <String, Uint8List>{};
      final settings = <String, String>{};
      final biosKeys = <String>{};
      for (final key in await store.keys()) {
        final kind = StorageKey.kindOf(key);
        if (kind == StorageKey.sram) {
          final data = await store.get(key);
          if (data != null) cache[key] = data;
        } else if (kind == StorageKey.settings) {
          final data = await store.get(key);
          if (data != null) settings[key] = utf8.decode(data);
        } else if (kind == StorageKey.bios) {
          biosKeys.add(key);
        }
      }
      return Storage._(store, cache, settings, biosKeys);
    } catch (e) {
      // run without persistence (e.g. storage is unavailable in the browser)
      return Storage._(null, {}, {}, {});
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

  /// returns the setting [name] saved before, or null
  String? setting(String name) => _settings[StorageKey.setting(name)];

  /// saves the setting [name]. the value can be read at once, and is kept
  /// across restarts if the persistent store is available.
  Future<void> setSetting(String name, String value) async {
    final key = StorageKey.setting(name);
    _settings[key] = value;
    try {
      await _store?.put(key, Uint8List.fromList(utf8.encode(value)));
    } catch (e) {
      onEvent("failed to save $name: $e");
    }
  }

  List<String> _biosKeysOf(String system) {
    final prefix = StorageKey.of(system, StorageKey.bios, "");
    return _biosKeys.where((k) => k.startsWith(prefix)).toList()..sort();
  }

  /// returns the file names of the BIOS of [system]
  List<String> biosNames(String system) {
    final prefix = StorageKey.of(system, StorageKey.bios, "");
    return [for (final k in _biosKeysOf(system)) k.substring(prefix.length)];
  }

  /// returns the BIOS files of [system], in the order of the file names
  Future<List<Uint8List>> bios(String system) async {
    final files = <Uint8List>[];
    for (final key in _biosKeysOf(system)) {
      final data = _biosData[key] ?? await _store?.get(key);
      if (data != null) files.add(data);
    }
    return files;
  }

  /// replaces the BIOS files of [system] with [files] of (name, data)
  Future<void> setBios(String system, List<(String, Uint8List)> files) async {
    for (final key in _biosKeysOf(system)) {
      _biosKeys.remove(key);
      _biosData.remove(key);
      await _store?.delete(key);
    }

    final store = _store;
    for (final (name, data) in files) {
      final key = StorageKey.of(system, StorageKey.bios, name);
      _biosKeys.add(key);
      if (store == null) {
        _biosData[key] = data;
      } else {
        await store.put(key, data);
      }
    }
  }

  void dispose() {
    saveIfDirty();
    _worker?.cancel();
  }

  @override
  void reset() {
    super.reset();
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
