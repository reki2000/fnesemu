import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../api.dart';

/// reads a part of a browser File by Blob.slice, without loading the whole
class BlobReadFile extends RandomReadFile {
  final web.File file;

  BlobReadFile(this.file);

  @override
  String get name => file.name;

  @override
  Future<int> length() async => file.size;

  @override
  Future<Uint8List> read(int offset, int length) async {
    final start = offset.clamp(0, file.size);
    final end = (offset + length).clamp(0, file.size);
    final buffer = await file.slice(start, end).arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  }

  @override
  Future<void> close() async {}
}

/// the files of a directory selected by the browser. the files are only
/// references: the contents are read when needed.
class WebDirectory extends PickedDirectory {
  @override
  final String name;
  final _files = <String, web.File>{};

  WebDirectory(this.name, Iterable<(String, web.File)> files) {
    for (final (path, file) in files) {
      _files[path] = file;
    }
  }

  /// directories of the browser cannot be opened again after a restart
  @override
  String? get restoreKey => null;

  @override
  Stream<String> walk() => Stream.fromIterable(_files.keys);

  @override
  RandomReadFile open(String path) => BlobReadFile(
      _files[path] ?? (throw ArgumentError("file not found: $path")));
}

/// a directory input, which all the major browsers support
Future<PickedDirectory?> pickWebDirectory() {
  final completer = Completer<PickedDirectory?>();

  final input = web.HTMLInputElement()
    ..type = "file"
    ..multiple = true;
  input.setAttribute("webkitdirectory", "");

  void complete(PickedDirectory? dir) {
    if (!completer.isCompleted) {
      completer.complete(dir);
    }
  }

  input.addEventListener(
      "change",
      (web.Event _) {
        final list = input.files;
        if (list == null || list.length == 0) {
          complete(null);
          return;
        }
        // webkitRelativePath is 'selected-folder/sub/file'
        String root = "";
        final files = <(String, web.File)>[];
        for (int i = 0; i < list.length; i++) {
          final f = list.item(i)!;
          final parts = f.webkitRelativePath.split("/");
          root = parts.first;
          files.add((parts.skip(1).join("/"), f));
        }
        complete(WebDirectory(root, files));
      }.toJS);
  input.addEventListener("cancel", ((web.Event _) => complete(null)).toJS);

  input.click();
  return completer.future;
}

/// a file input
Future<List<RandomReadFile>?> pickWebFiles(
    {List<String>? extensions, bool multiple = false}) {
  final completer = Completer<List<RandomReadFile>?>();

  final input = web.HTMLInputElement()
    ..type = "file"
    ..multiple = multiple;
  if (extensions != null) {
    input.accept = extensions.map((e) => ".$e").join(",");
  }

  void complete(List<RandomReadFile>? files) {
    if (!completer.isCompleted) {
      completer.complete(files);
    }
  }

  input.addEventListener(
      "change",
      (web.Event _) {
        final list = input.files;
        complete(list == null || list.length == 0
            ? null
            : [
                for (int i = 0; i < list.length; i++)
                  BlobReadFile(list.item(i)!)
              ]);
      }.toJS);
  input.addEventListener("cancel", ((web.Event _) => complete(null)).toJS);

  input.click();
  return completer.future;
}
