import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'image_file.dart';

/// reads a part of a browser File by Blob.slice, without loading the whole
class WebImageFile extends ImageFile {
  final web.File file;

  WebImageFile(this.file);

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

/// files selected together: a .cue file and its track files, or a single
/// .iso/.bin file
class WebDiscSource extends DiscSource {
  final List<web.File> files;
  final WebImageFile _main;

  WebDiscSource(this.files, web.File main) : _main = WebImageFile(main);

  @override
  ImageFile get main => _main;

  @override
  Future<ImageFile> open(String name) async {
    final base = name.split(RegExp(r'[\\/]')).last.toLowerCase();
    for (final f in files) {
      if (f.name.toLowerCase() == base) {
        return WebImageFile(f);
      }
    }
    throw ArgumentError("cdrom: $name is not selected with the .cue file");
  }

  @override
  Future<void> close() async {}
}

/// local paths are not accessible on the web
DiscSource discSourceFromPath(String path) =>
    throw UnsupportedError("cdrom: cannot open $path on the web");

/// lets the user select a .cue file with its track files, or a .iso/.bin
/// file. returns null if canceled.
Future<DiscSource?> pickDiscSource() {
  final completer = Completer<DiscSource?>();

  final input = web.HTMLInputElement()
    ..type = "file"
    ..multiple = true
    ..accept = ".cue,.iso,.bin,.img";

  void complete(DiscSource? source) {
    if (!completer.isCompleted) {
      completer.complete(source);
    }
  }

  input.addEventListener(
      "change",
      (web.Event _) {
        final list = input.files;
        final files = <web.File>[
          for (int i = 0; i < (list?.length ?? 0); i++) list!.item(i)!
        ];
        bool hasExt(web.File f, List<String> exts) =>
            exts.any((e) => f.name.toLowerCase().endsWith(e));

        final main = files.where((f) => hasExt(f, [".cue"])).firstOrNull ??
            files.where((f) => hasExt(f, [".iso", ".bin", ".img"])).firstOrNull;
        complete(main == null ? null : WebDiscSource(files, main));
      }.toJS);
  input.addEventListener("cancel", ((web.Event _) => complete(null)).toJS);

  input.click();
  return completer.future;
}
