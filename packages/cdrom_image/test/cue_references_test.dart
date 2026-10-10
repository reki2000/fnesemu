import 'dart:typed_data';

import 'package:cdrom_image/cdrom_image.dart';
import 'package:cdrom_image/memory.dart';
import 'package:test/test.dart';

Uint8List text(String s) => Uint8List.fromList(s.codeUnits);

String cue(List<String> names) => [
      for (int i = 0; i < names.length; i++)
        'FILE "${names[i]}" BINARY\n  TRACK ${i + 1} MODE1/2352\n    INDEX 01 00:00:00'
    ].join("\n");

final bin = Uint8List(2352 * 4);

/// the paths of the files [path] of [files] refers to
Future<List<String>> referenced(
    Map<String, Uint8List> files, String path) async {
  final dir = MemoryDirectory.of(files);
  final (_, refs) = await DiscImage.parse(dir.files.values, dir.files[path]!);
  return [for (final f in refs) f.path];
}

Matcher missing(String name) => throwsA(isA<DiscParseException>()
    .having((e) => e.referencedPath, 'referencedPath', name));

class _BrokenFile extends DiscFile {
  @override
  String get path => 'broken.cue';
  @override
  Future<int> length() async => throw const FileSystemError();
  @override
  Future<Uint8List> read(int offset, int length) async =>
      throw const FileSystemError();
}

class FileSystemError implements Exception {
  const FileSystemError();
}

void main() {
  test('the files a cue refers to are returned', () async {
    expect(
        await referenced({
          "game/game.cue":
              text(cue(["game (Track 1).bin", "game (Track 2).bin"])),
          "game/game (Track 1).bin": bin,
          "game/game (Track 2).bin": bin,
          "single.bin": bin,
        }, "game/game.cue"),
        ["game/game (Track 1).bin", "game/game (Track 2).bin"]);
  });

  test('file names are matched ignoring the case, with back slashes and ..',
      () async {
    expect(
        await referenced({
          "x/game.cue": text(cue(["GAME.BIN", "..\\shared\\Track2.bin"])),
          "x/game.bin": bin,
          "shared/track2.BIN": bin,
        }, "x/game.cue"),
        ["x/game.bin", "shared/track2.BIN"]);
  });

  test('a missing file or a file outside of the directory is an error',
      () async {
    final files = {
      "a/a.cue": text(cue(["a1.bin", "a2.bin"])),
      "a/a1.bin": bin,
      "b.cue": text(cue(["../outside.bin"])),
    };
    expect(referenced(files, "a/a.cue"), missing("a2.bin"));
    expect(referenced(files, "b.cue"), missing("../outside.bin"));
  });

  test('a cue without tracks is an error', () async {
    expect(referenced({"empty.cue": text("")}, "empty.cue"),
        throwsA(isA<DiscParseException>()));
  });

  test('an error of the storage is given to the caller', () async {
    final file = _BrokenFile();
    expect(DiscImage.parse([file], file), throwsA(isA<FileSystemError>()));
  });

  test('an iso or a bin refers to no file', () async {
    expect(await referenced({"a.iso": bin}, "a.iso"), isEmpty);
  });
}
