import 'dart:typed_data';

import 'package:idb_shim/idb.dart';

import 'factory_io.dart' if (dart.library.js_interop) 'factory_web.dart';

/// Persistent key-value store of binary data.
/// Backed by IndexedDB on web and by a sembast file on native platforms.
class BlobStore {
  static const _dbName = "fnesemu";
  static const _storeName = "blobs";

  final Database _db;

  BlobStore._(this._db);

  static Future<BlobStore> open({IdbFactory? factory}) async {
    factory ??= await idbFactory();
    final db = await factory.open(_dbName, version: 1,
        onUpgradeNeeded: (VersionChangeEvent e) {
      if (e.oldVersion < 1) {
        e.database.createObjectStore(_storeName);
      }
    });
    return BlobStore._(db);
  }

  Future<T> _run<T>(String mode, Future<T> Function(ObjectStore) action) async {
    final txn = _db.transaction(_storeName, mode);
    final result = await action(txn.objectStore(_storeName));
    await txn.completed;
    return result;
  }

  Future<Uint8List?> get(String key) => _run(idbModeReadOnly,
      (store) async => await store.getObject(key) as Uint8List?);

  Future<void> put(String key, Uint8List data) =>
      _run(idbModeReadWrite, (store) => store.put(data, key));

  Future<void> delete(String key) =>
      _run(idbModeReadWrite, (store) => store.delete(key));

  Future<List<String>> keys() => _run(idbModeReadOnly,
      (store) async => (await store.getAllKeys()).cast<String>());

  void close() => _db.close();
}
