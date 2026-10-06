import 'package:flutter/services.dart';

import '../api.dart';
import 'io_impl.dart';

const _channel = MethodChannel('mp_bigfile_picker');

// on iOS and macOS, a security scoped directory or file is a local one while
// it is accessed. the restore key is the bookmark of it.

Future<PickedDirectory?> pickDarwinDirectory({String? dialogTitle}) async {
  final r = await _channel
      .invokeMapMethod<String, String>('pickDirectory', {'title': dialogTitle});
  return r == null ? null : IoDirectory.withKey(r['path']!, r['key']);
}

Future<List<RandomReadFile>?> pickDarwinFiles(
    {List<String>? extensions,
    bool multiple = false,
    String? dialogTitle}) async {
  final r = await _channel.invokeListMethod<Map>('pickFiles', {
    'extensions': extensions,
    'multiple': multiple,
    'title': dialogTitle,
  });
  return r
      ?.map((e) =>
          IoReadFile(e['path'] as String, restoreKey: e['key'] as String?))
      .toList();
}

Future<PickedDirectory?> restoreDarwinDirectory(String restoreKey) async {
  final r = await _restore(restoreKey);
  return r == null ? null : IoDirectory.withKey(r['path']!, r['key']);
}

Future<RandomReadFile?> restoreDarwinFile(String restoreKey) async {
  final r = await _restore(restoreKey);
  return r == null ? null : IoReadFile(r['path']!, restoreKey: r['key']);
}

/// the path and the key, which is made again if it is stale
Future<Map<String, String>?> _restore(String restoreKey) async {
  try {
    return await _channel.invokeMapMethod<String, String>(
        'restore', restoreKey);
  } on PlatformException {
    return null;
  }
}
