import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart' show MethodChannel, PlatformException;

import '../api.dart';

const _channel = MethodChannel('mp_bigfile_picker');

// a document of the Storage Access Framework is opened by the platform, and
// its file descriptor is read by pread(2) directly. dart:io cannot use a file
// descriptor, and opening /proc/self/fd/N again may be denied for the files
// which are not media.

final _libc = DynamicLibrary.open('libc.so');
final _pread = _libc.lookupFunction<
    IntPtr Function(Int32, Pointer<Uint8>, Size, Int64),
    int Function(int, Pointer<Uint8>, int, int)>('pread64');
final _lseek = _libc.lookupFunction<Int64 Function(Int32, Int64, Int32),
    int Function(int, int, int)>('lseek64');
final _close =
    _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('close');

const _seekEnd = 2;

class SafReadFile extends RandomReadFile {
  /// the document uri
  final String uri;
  @override
  final String name;
  @override
  final String? restoreKey;
  Future<int>? _fd;

  SafReadFile(this.uri, this.name, {this.restoreKey});

  Future<int> _open() => _fd ??= _channel
      .invokeMethod<int>('openFd', uri)
      .then((fd) => fd ?? (throw StateError("cannot open: $name")));

  @override
  Future<int> length() async {
    final n = _lseek(await _open(), 0, _seekEnd);
    if (n < 0) {
      throw UnsupportedError("not seekable: $name");
    }
    return n;
  }

  @override
  Future<Uint8List> read(int offset, int length) async {
    final fd = await _open();
    final buf = malloc<Uint8>(length);
    try {
      int done = 0;
      while (done < length) {
        final n = _pread(fd, buf + done, length - done, offset + done);
        if (n < 0) throw StateError("read failed: $name");
        if (n == 0) break; // the end of the file
        done += n;
      }
      return Uint8List.fromList(buf.asTypedList(done));
    } finally {
      malloc.free(buf);
    }
  }

  @override
  Future<void> close() async {
    final fd = _fd;
    _fd = null;
    if (fd != null) {
      _close(await fd);
    }
  }
}

/// a tree of the Storage Access Framework. the restore key is the tree uri,
/// whose permission is persisted.
class SafDirectory extends PickedDirectory {
  final String treeUri;
  @override
  final String name;

  SafDirectory(this.treeUri, this.name);

  @override
  String? get restoreKey => treeUri;

  // the document uri of each path found by [walk]
  final _uris = <String, String>{};

  @override
  Stream<String> walk() async* {
    // [path, uri, path, uri, ...]
    final list =
        await _channel.invokeListMethod<String>('walk', treeUri) ?? const [];
    _uris.clear();
    for (int i = 0; i + 1 < list.length; i += 2) {
      _uris[list[i]] = list[i + 1];
      yield list[i];
    }
  }

  /// [path] must be one found by [walk]
  @override
  RandomReadFile open(String path) => SafReadFile(
      _uris[path] ?? (throw ArgumentError("file not found: $path")),
      path.split('/').last);
}

Future<PickedDirectory?> pickSafDirectory() async {
  final r = await _channel.invokeMapMethod<String, String>('pickDirectory');
  return r == null ? null : SafDirectory(r['uri']!, r['name']!);
}

Future<PickedDirectory?> restoreSafDirectory(String treeUri) async {
  try {
    final name =
        await _channel.invokeMethod<String>('restoreDirectory', treeUri);
    return name == null ? null : SafDirectory(treeUri, name);
  } on PlatformException {
    return null;
  }
}

/// the restore key of a file is its document uri, whose permission is
/// persisted
Future<List<RandomReadFile>?> pickSafFiles({bool multiple = false}) async {
  final r =
      await _channel.invokeListMethod<Map>('pickFiles', {'multiple': multiple});
  return r
      ?.map((e) => SafReadFile(e['uri'] as String, e['name'] as String,
          restoreKey: e['uri'] as String))
      .toList();
}

Future<RandomReadFile?> restoreSafFile(String uri) async {
  try {
    final name = await _channel.invokeMethod<String>('restoreFile', uri);
    return name == null ? null : SafReadFile(uri, name, restoreKey: uri);
  } on PlatformException {
    return null;
  }
}
