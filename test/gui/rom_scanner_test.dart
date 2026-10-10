import 'dart:io';
import 'dart:typed_data';

import 'package:cdrom_image/cdrom_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/gui/rom_scanner.dart';
import 'package:mp_bigfile_picker/io.dart';

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

  test('a cue with a missing file is marked skipped, its files are not listed',
      () async {
    final r = await RomScanner.scan(MemoryPickedDirectory({
      "a/a.cue": text(cue(["a1.bin", "a2.bin"])),
      "a/a1.bin": bin, // a2.bin is missing
      "b/b.cue": text(cue(["b.bin"])),
      "b/b.bin": bin,
    }));
    expect(r.items.map((i) => i.path), ["a/a.cue", "b/b.cue"]);
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
    final image = await DiscImage.open(r.sourceOf(r.items.single));
    expect(image.totalSectors, 4);
    await image.close();
  });

  test('a local directory lists the files recursively', () async {
    final dir = Directory.systemTemp.createTempSync('scan_test_');
    addTearDown(() => dir.deleteSync(recursive: true));
    Directory('${dir.path}/a/b').createSync(recursive: true);
    File('${dir.path}/a/b/x.cue').writeAsStringSync(cue(["x.bin"]));
    File('${dir.path}/a/b/x.bin').writeAsBytesSync(bin);
    File('${dir.path}/y.iso').writeAsBytesSync(bin);

    final r = await RomScanner.scan(IoDirectory(dir.path));
    expect(r.items.map((i) => i.path), ["a/b/x.cue", "y.iso"]);

    final image = await DiscImage.open(r.sourceOf(r.items.first));
    expect(image.totalSectors, 4);
    await image.close();
  });
}
