import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../api.dart';
import 'web_impl.dart';

@JS('showDirectoryPicker')
external JSFunction? get _directoryPicker;
@JS('showDirectoryPicker')
external JSPromise<_Handle> _pickDirectory(_ReadOptions options);

extension type _ReadOptions._(JSObject _) implements JSObject {
  external factory _ReadOptions({String mode});
}

extension type _Handle(JSObject _) implements JSObject {
  external String get name;
  external String get kind;
  external JSPromise<JSString> queryPermission(_ReadOptions options);
  external JSPromise<JSString> requestPermission(_ReadOptions options);
  external JSPromise<JSBoolean> isSameEntry(_Handle other);
  external _Iterator values();
  external JSPromise<_Handle> getDirectoryHandle(String name);
  external JSPromise<_Handle> getFileHandle(String name);
  external JSPromise<web.File> getFile();
}

extension type _Iterator(JSObject _) implements JSObject {
  external JSPromise<_Next> next();
}
extension type _Next(JSObject _) implements JSObject {
  external bool get done;
  external _Handle get value;
}

Future<JSAny?> _request(web.IDBRequest request) {
  final result = Completer<JSAny?>();
  request.onsuccess = ((web.Event _) => result.complete(request.result)).toJS;
  request.onerror = ((web.Event _) => result.completeError(
      StateError(request.error?.message ?? 'Directory storage failed'))).toJS;
  return result.future;
}

Future<web.IDBDatabase> _database() async {
  final request = web.window.indexedDB.open('mp-bigfile-picker-directories', 1);
  request.onupgradeneeded = ((web.Event _) {
    (request.result as web.IDBDatabase).createObjectStore('directories');
  }).toJS;
  return (await _request(request)) as web.IDBDatabase;
}

Future<String> _saveHandle(_Handle handle) async {
  final db = await _database();
  try {
    final store = db.transaction('directories'.toJS).objectStore('directories');
    final results = await Future.wait(
        [_request(store.getAllKeys()), _request(store.getAll())]);
    final keys = (results[0] as JSArray<JSString>).toDart;
    final handles = (results[1] as JSArray<JSObject>).toDart;
    for (var i = 0; i < handles.length; i++) {
      if ((await handle.isSameEntry(_Handle(handles[i])).toDart).toDart) {
        return keys[i].toDart;
      }
    }
    final key = 'fs-access:${DateTime.now().microsecondsSinceEpoch}';
    final txn = db.transaction('directories'.toJS, 'readwrite');
    final completed = Completer<void>();
    txn.oncomplete = ((web.Event _) => completed.complete()).toJS;
    txn.onabort = ((web.Event _) => completed.completeError(
        StateError(txn.error?.message ?? 'Directory storage failed'))).toJS;
    await Future.wait([
      _request(txn.objectStore('directories').put(handle, key.toJS)),
      completed.future,
    ]);
    return key;
  } finally {
    db.close();
  }
}

Future<PickedDirectory?> pickAccessDirectory() async {
  if (_directoryPicker == null) return pickWebDirectory();
  try {
    // Invoke the picker before any await to retain the user's activation.
    final handle = await _pickDirectory(_ReadOptions(mode: 'read')).toDart;
    String? key;
    try {
      key = await _saveHandle(handle);
    } catch (_) {
      // Access remains usable this session when IndexedDB is unavailable.
    }
    return _AccessDirectory(handle, key);
  } catch (e) {
    if ((e as JSObject).getProperty<JSString?>('name'.toJS)?.toDart ==
        'AbortError') {
      return null;
    }
    rethrow;
  }
}

Future<PickedDirectory?> restoreAccessDirectory(String key,
    {bool requestPermission = false}) async {
  if (!key.startsWith('fs-access:') || _directoryPicker == null) return null;
  final db = await _database();
  try {
    final value = await _request(db
        .transaction('directories'.toJS)
        .objectStore('directories')
        .get(key.toJS));
    if (value == null) return null;
    final handle = _Handle(value as JSObject);
    final options = _ReadOptions(mode: 'read');
    var permission = (await handle.queryPermission(options).toDart).toDart;
    if (permission != 'granted' && requestPermission) {
      permission = (await handle.requestPermission(options).toDart).toDart;
    }
    return permission == 'granted' ? _AccessDirectory(handle, key) : null;
  } finally {
    db.close();
  }
}

class _AccessDirectory extends PickedDirectory {
  final _Handle handle;
  @override
  final String? restoreKey;
  _AccessDirectory(this.handle, this.restoreKey);
  @override
  String get name => handle.name;
  @override
  Stream<String> walk() async* {
    final pending = <(_Handle, String)>[(handle, '')];
    while (pending.isNotEmpty) {
      final (directory, prefix) = pending.removeLast();
      final entries = directory.values();
      while (true) {
        final next = await entries.next().toDart;
        if (next.done) break;
        final entry = next.value;
        final path = '$prefix${entry.name}';
        if (entry.kind == 'directory') {
          pending.add((entry, '$path/'));
        } else {
          yield path;
        }
      }
    }
  }

  @override
  RandomReadFile open(String path) => _AccessFile(handle, path);
}

class _AccessFile extends RandomReadFile {
  final _Handle directory;
  final String path;
  Future<BlobReadFile>? _file;
  _AccessFile(this.directory, this.path);
  @override
  String get name => path.split('/').last;
  Future<BlobReadFile> _open() => _file ??= _resolve();
  Future<BlobReadFile> _resolve() async {
    final parts = path.split('/');
    if (parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw ArgumentError('Invalid relative path');
    }
    var parent = directory;
    for (final part in parts.take(parts.length - 1)) {
      parent = await parent.getDirectoryHandle(part).toDart;
    }
    final file = await parent.getFileHandle(parts.last).toDart;
    return BlobReadFile(await file.getFile().toDart);
  }

  @override
  Future<int> length() async => (await _open()).length();
  @override
  Future<Uint8List> read(int offset, int length) async =>
      (await _open()).read(offset, length);
  @override
  Future<void> close() async {
    _file = null;
  }
}
