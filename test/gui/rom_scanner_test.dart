import 'dart:typed_data';

import 'package:cdrom_image/cdrom_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/gui/rom_scanner.dart';

import 'memory_picked_directory.dart';

Uint8List text(String s) => Uint8List.fromList(s.codeUnits);

String cue(List<String> names) => [
      for (int i = 0; i < names.length; i++)
        'FILE "${names[i]}" BINARY\n  TRACK ${i + 1} MODE1/2352\n    INDEX 01 00:00:00'
    ].join("\n");

final bin = Uint8List(2352 * 4);

void main() {
  test('a cue is listed, the files it refers to are not', () async {
    final r = await RomScanner.scan(MemoryPickedDirectory({
      "game/game.cue": text(cue(["game (Track 1).bin", "game (Track 2).bin"])),
      "game/game (Track 1).bin": bin,
      "game/game (Track 2).bin": bin,
      "single.iso": bin,
      "sub/deep/other.bin": bin,
      "readme.txt": text("x"),
    }));
    expect(r.items.map((i) => i.path),
        ["game/game.cue", "readme.txt", "single.iso", "sub/deep/other.bin"]);
    expect(r.skipped, isEmpty);
  });

  test('game list includes every remaining file after cue references',
      () async {
    final r = await RomScanner.scan(MemoryPickedDirectory({
      'game.cue': text(cue(['track.bin'])),
      'track.bin': bin,
      'fixture.gb': bin,
      'archive.zip': bin,
      'readme.txt': text('fixture'),
      'invalid.cue': text(cue(['missing.bin'])),
    }));
    expect(r.items.map((item) => item.path), [
      'archive.zip',
      'fixture.gb',
      'game.cue',
      'invalid.cue',
      'readme.txt',
    ]);
    expect(r.skipped, ['invalid.cue']);
  });

  test('a cue with a missing file is marked skipped, with its files listed',
      () async {
    final r = await RomScanner.scan(MemoryPickedDirectory({
      "a/a.cue": text(cue(["a1.bin", "a2.bin"])),
      "a/a1.bin": bin, // a2.bin is missing
      "b/b.cue": text(cue(["b.bin"])),
      "b/b.bin": bin,
    }));
    // the files of a broken cue are not known to be its parts
    expect(r.items.map((i) => i.path), ["a/a.cue", "a/a1.bin", "b/b.cue"]);
    expect(r.skipped, ["a/a.cue"]);
  });

  test('progress is reported while listing and checking', () async {
    final progress = <ScanProgress>[];
    await RomScanner.scan(
        MemoryPickedDirectory({
          "a.cue": text(cue(["a.bin"])),
          "a.bin": bin,
        }),
        onProgress: progress.add);
    expect(progress.first.isListing, true);
    expect(progress.where((p) => p.isListing).last.files, 2);
    expect(progress.last.isListing, false);
    expect(progress.last.cues, 1);
    expect(progress.last.checkedCues, 1);
    expect(progress.last.found, 1);
  });

  test('scan can be cancelled', () async {
    final r = await RomScanner.scan(
        MemoryPickedDirectory({"a.iso": bin, "b.iso": bin}),
        isCancelled: () => true);
    expect(r.cancelled, true);
    expect(r.items, isEmpty);
  });

  test('the source of an item finds the files of the cue in the folder',
      () async {
    final folder = MemoryPickedDirectory({
      "g/game.cue": text('FILE "GAME.BIN" BINARY\n'
          '  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n'),
      "g/game.bin": bin,
    });
    final r = await RomScanner.scan(folder);
    final (file, files) = r.sourceOf(r.items.single);
    final (image, _) = await DiscImage.parse(file, files: files);
    expect(image.totalSectors, 4);
  });
}
