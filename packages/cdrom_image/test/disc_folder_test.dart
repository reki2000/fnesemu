import 'dart:typed_data';

import 'package:cdrom_image/disc_folder.dart';
import 'package:cdrom_image/memory.dart';
import 'package:test/test.dart';

Uint8List text(String s) => Uint8List.fromList(s.codeUnits);

String cue(List<String> names) => [
      for (int i = 0; i < names.length; i++)
        'FILE "${names[i]}" BINARY\n  TRACK ${i + 1} MODE1/2352\n    INDEX 01 00:00:00'
    ].join("\n");

final bin = Uint8List(2352 * 4);

DiscFolder folder(Map<String, Uint8List> files) =>
    DiscFolder(MemoryDirectory.of(files), files.keys);

void main() {
  test('the files a cue refers to are found', () async {
    final refs = await folder({
      "game/game.cue": text(cue(["game (Track 1).bin", "game (Track 2).bin"])),
      "game/game (Track 1).bin": bin,
      "game/game (Track 2).bin": bin,
      "single.bin": bin,
    }).cueReferences("game/game.cue");
    expect(refs.found, ["game/game (Track 1).bin", "game/game (Track 2).bin"]);
    expect(refs.missing, isEmpty);
    expect(refs.isComplete, true);
  });

  test('file names are matched ignoring the case, with back slashes and ..',
      () async {
    final refs = await folder({
      "x/game.cue": text(cue(["GAME.BIN", "..\\shared\\Track2.bin"])),
      "x/game.bin": bin,
      "shared/track2.BIN": bin,
    }).cueReferences("x/game.cue");
    expect(refs.found, ["x/game.bin", "shared/track2.BIN"]);
    expect(refs.isComplete, true);
  });

  test('missing files and files outside of the folder are not complete',
      () async {
    final f = folder({
      "a/a.cue": text(cue(["a1.bin", "a2.bin"])),
      "a/a1.bin": bin,
      "b.cue": text(cue(["../outside.bin"])),
      "empty.cue": text(""),
    });
    final a = await f.cueReferences("a/a.cue");
    expect(a.found, ["a/a1.bin"]);
    expect(a.missing, ["a2.bin"]);
    expect(a.isComplete, false);
    expect((await f.cueReferences("b.cue")).missing, ["../outside.bin"]);
    expect((await f.cueReferences("empty.cue")).isComplete, false);
  });

  test('an unreadable cue is reported', () async {
    final refs = await DiscFolder(MemoryDirectory.of({}), ["lost.cue"])
        .cueReferences("lost.cue");
    expect(refs.readable, false);
    expect(refs.isComplete, false);
  });
}
