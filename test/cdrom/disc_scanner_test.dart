import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu/cdrom/async_cdrom_drive.dart';
import 'package:fnesemu/cdrom/disc_folder.dart';
import 'package:fnesemu/cdrom/disc_source_local.dart';
import 'package:fnesemu/cdrom/image_file.dart';
import 'package:test/test.dart';

class MemoryFolder extends DiscFolder {
  final Map<String, Uint8List> files;
  MemoryFolder(this.files);

  @override
  String get name => "root";

  @override
  Stream<FolderFile> list() async* {
    for (final p in files.keys) {
      yield FolderFile(p);
    }
  }

  @override
  ImageFile file(String path) => MemoryImageFile(path, files[path]!);
}

Uint8List text(String s) => Uint8List.fromList(s.codeUnits);

String cue(List<String> names) => [
      for (int i = 0; i < names.length; i++)
        'FILE "${names[i]}" BINARY\n  TRACK ${i + 1} MODE1/2352\n    INDEX 01 00:00:00'
    ].join("\n");

final bin = Uint8List(2352 * 4);

void main() {
  test('a cue is listed, the files it refers to are not', () async {
    final r = await DiscScanner.scan(MemoryFolder({
      "game/game.cue": text(cue(["game (Track 1).bin", "game (Track 2).bin"])),
      "game/game (Track 1).bin": bin,
      "game/game (Track 2).bin": bin,
      "single.iso": bin,
      "sub/deep/other.bin": bin,
      "readme.txt": text("x"),
    }));
    expect(r.items.map((i) => i.path),
        ["game/game.cue", "single.iso", "sub/deep/other.bin"]);
    expect(r.skipped, isEmpty);
  });

  test('a cue with a missing file is skipped, its files are not listed',
      () async {
    final r = await DiscScanner.scan(MemoryFolder({
      "a/a.cue": text(cue(["a1.bin", "a2.bin"])),
      "a/a1.bin": bin, // a2.bin is missing
      "b/b.cue": text(cue(["b.bin"])),
      "b/b.bin": bin,
    }));
    expect(r.items.map((i) => i.path), ["b/b.cue"]);
    expect(r.skipped, ["a/a.cue"]);
  });

  test('file names are matched ignoring the case, with back slashes and ..',
      () async {
    final r = await DiscScanner.scan(MemoryFolder({
      "x/game.cue": text(cue(["GAME.BIN", "..\\shared\\Track2.bin"])),
      "x/game.bin": bin,
      "shared/track2.BIN": bin,
    }));
    expect(r.items.map((i) => i.path), ["x/game.cue"]);
  });

  test('a cue referring outside of the folder is skipped', () async {
    final r = await DiscScanner.scan(MemoryFolder({
      "game.cue": text(cue(["../outside.bin"])),
    }));
    expect(r.items, isEmpty);
    expect(r.skipped, ["game.cue"]);
  });

  test('progress is reported while listing and checking', () async {
    final progress = <ScanProgress>[];
    await DiscScanner.scan(
        MemoryFolder({
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
    final r = await DiscScanner.scan(
        MemoryFolder({"a.iso": bin, "b.iso": bin}),
        isCancelled: () => true);
    expect(r.cancelled, true);
    expect(r.items, isEmpty);
  });

  test('FolderDiscSource finds the files of the cue in the folder', () async {
    final folder = MemoryFolder({
      "g/game.cue": text('FILE "GAME.BIN" BINARY\n'
          '  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n'),
      "g/game.bin": bin,
    });
    final r = await DiscScanner.scan(folder);
    final drive = AsyncCdromDrive();
    await drive.insert(r.sourceOf(r.items.single));
    expect(drive.status.isReady, true);
    expect(drive.status.toc.totalSectors, 4);
  });

  test('LocalDiscFolder lists the files recursively', () async {
    final dir = Directory.systemTemp.createTempSync('scan_test_');
    addTearDown(() => dir.deleteSync(recursive: true));
    Directory('${dir.path}/a/b').createSync(recursive: true);
    File('${dir.path}/a/b/x.cue')
        .writeAsStringSync(cue(["x.bin"]));
    File('${dir.path}/a/b/x.bin').writeAsBytesSync(bin);
    File('${dir.path}/y.iso').writeAsBytesSync(bin);

    final r = await DiscScanner.scan(LocalDiscFolder(dir.path));
    expect(r.items.map((i) => i.path), ["a/b/x.cue", "y.iso"]);

    final drive = AsyncCdromDrive();
    await drive.insert(r.sourceOf(r.items.first));
    expect(drive.status.isReady, true);
    await drive.insert();
  });
}
