@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mp_bigfile_picker/mp_bigfile_picker.dart';
import 'package:web/web.dart' as web;

void main() {
  test(
      'directory handle persists, is deduplicated, and restores readable files',
      () async {
    final root = await web.window.navigator.storage.getDirectory().toDart;
    final directory = await root
        .getDirectoryHandle('fixture-${DateTime.now().microsecondsSinceEpoch}',
            web.FileSystemGetDirectoryOptions(create: true))
        .toDart;
    final file = await directory
        .getFileHandle('fixture.gb', web.FileSystemGetFileOptions(create: true))
        .toDart;
    final writer = await file.createWritable().toDart;
    await writer.write(Uint8List.fromList([1, 2, 3]).toJS).toDart;
    await writer.close().toDart;
    final original = web.window.getProperty<JSAny?>('showDirectoryPicker'.toJS);
    addTearDown(
        () => web.window.setProperty('showDirectoryPicker'.toJS, original));
    addTearDown(() async => root
        .removeEntry(
            directory.name, web.FileSystemRemoveOptions(recursive: true))
        .toDart);
    // Use a genuine browser handle: IndexedDB must structured-clone it.
    web.window.setProperty(
        'showDirectoryPicker'.toJS, (() => Future.value(directory).toJS).toJS);
    final picked = (await pickDirectory())!;
    expect(picked.restoreKey, startsWith('fs-access:'));
    expect(await picked.walk().toList(), ['fixture.gb']);
    final again = (await pickDirectory())!;
    expect(again.restoreKey, picked.restoreKey);
    final restored = (await restoreDirectory(picked.restoreKey!))!;
    expect(restored.name, directory.name);
    final bytes = restored.open('fixture.gb');
    expect(await bytes.read(1, 2), [2, 3]);
    await bytes.close();
    expect(await bytes.length(), 3);
    expect(await restoreDirectory('fs-access:missing'), isNull);
  });

  test('restoration requests permission only after an explicit user action',
      () async {
    final root = await web.window.navigator.storage.getDirectory().toDart;
    final directory = await root
        .getDirectoryHandle(
            'permission-${DateTime.now().microsecondsSinceEpoch}',
            web.FileSystemGetDirectoryOptions(create: true))
        .toDart;
    final picker = web.window.getProperty<JSAny?>('showDirectoryPicker'.toJS);
    web.window.setProperty(
        'showDirectoryPicker'.toJS, (() => Future.value(directory).toJS).toJS);
    addTearDown(
        () => web.window.setProperty('showDirectoryPicker'.toJS, picker));
    addTearDown(() async => root
        .removeEntry(
            directory.name, web.FileSystemRemoveOptions(recursive: true))
        .toDart);
    final key = (await pickDirectory())!.restoreKey!;
    final prototype = web.window
        .getProperty<JSObject>('FileSystemHandle'.toJS)
        .getProperty<JSObject>('prototype'.toJS);
    final query = prototype.getProperty<JSAny?>('queryPermission'.toJS);
    final request = prototype.getProperty<JSAny?>('requestPermission'.toJS);
    addTearDown(() {
      prototype.setProperty('queryPermission'.toJS, query);
      prototype.setProperty('requestPermission'.toJS, request);
    });
    var requests = 0;
    prototype.setProperty(
        'queryPermission'.toJS, (() => Future.value('prompt'.toJS).toJS).toJS);
    prototype.setProperty(
        'requestPermission'.toJS,
        (() {
          requests++;
          return Future.value('granted'.toJS).toJS;
        }).toJS);
    expect(await restoreDirectory(key), isNull);
    expect(requests, 0);
    expect(await restoreDirectory(key, requestPermission: true), isNotNull);
    expect(requests, 1);
  });

  test('canceling the directory picker returns null', () async {
    final original = web.window.getProperty<JSAny?>('showDirectoryPicker'.toJS);
    addTearDown(
        () => web.window.setProperty('showDirectoryPicker'.toJS, original));
    web.window.setProperty(
        'showDirectoryPicker'.toJS,
        (() => JSPromise<JSObject>((JSFunction resolve, JSFunction reject) {
              reject.callAsFunction(
                  null, web.DOMException('Canceled', 'AbortError'));
            }.toJS)).toJS);
    expect(await pickDirectory(), isNull);
  });
}
