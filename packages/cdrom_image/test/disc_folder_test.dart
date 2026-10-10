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

DiscFolder folder(Map<String, Uint8List> files) =>
    DiscFolder(MemoryDirectory.of(files).files.values);

void main() {
  test('the files a cue refers to are found', () async {
    final image = await folder({
      "game/game.cue": text(cue(["game (Track 1).bin", "game (Track 2).bin"])),
      "game/game (Track 1).bin": bin,
      "game/game (Track 2).bin": bin,
      "single.bin": bin,
    }).parse("game/game.cue");
    expect(image.referredFiles,
        ["game/game (Track 1).bin", "game/game (Track 2).bin"]);
    expect(image.missingFiles, isEmpty);
    expect(image.isComplete, true);
  });

  test('file names are matched ignoring the case, with back slashes and ..',
      () async {
    final image = await folder({
      "x/game.cue": text(cue(["GAME.BIN", "..\\shared\\Track2.bin"])),
      "x/game.bin": bin,
      "shared/track2.BIN": bin,
    }).parse("x/game.cue");
    expect(image.referredFiles, ["x/game.bin", "shared/track2.BIN"]);
    expect(image.isComplete, true);
  });

  test('missing files and files outside of the folder are not complete',
      () async {
    final f = folder({
      "a/a.cue": text(cue(["a1.bin", "a2.bin"])),
      "a/a1.bin": bin,
      "b.cue": text(cue(["../outside.bin"])),
      "empty.cue": text(""),
    });
    final a = await f.parse("a/a.cue");
    expect(a.referredFiles, ["a/a1.bin"]);
    expect(a.missingFiles, ["a2.bin"]);
    expect(a.isComplete, false);
    expect((await f.parse("b.cue")).missingFiles, ["../outside.bin"]);
    expect((await f.parse("empty.cue")).isComplete, false);
  });

  test('an unreadable cue throws', () async {
    expect(DiscFolder([]).parse("lost.cue"), throwsA(anything));
  });

  test('an iso or a bin is an image by itself', () async {
    final image = await folder({"a.iso": bin}).parse("a.iso");
    expect(image.referredFiles, isEmpty);
    expect(image.isComplete, true);
  });

  test('the parsed image is opened with the files it refers to', () async {
    final image = await folder({
      "g/game.cue": text(cue(["GAME.BIN"])),
      "g/game.bin": bin,
    }).parse("g/game.cue");
    final disc = await parseSource(image.open());
    expect(disc.totalSectors, 4);
  });
}
