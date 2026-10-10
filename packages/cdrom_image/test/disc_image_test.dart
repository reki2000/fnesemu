import 'dart:typed_data';

import 'package:cdrom_image/cdrom_image.dart';
import 'package:cdrom_image/disc_image.dart' show ParsedDiscImage;
import 'package:cdrom_image/memory.dart';
import 'package:test/test.dart';

const size = DiscImage.sectorSize;

/// the image of [disc], the arguments of [DiscImage.parse]
Future<DiscImage> open((DiscFile, Iterable<DiscFile>) disc) async =>
    (await DiscImage.parse(disc.$2, disc.$1)).$1;

Future<DiscImage> insert(String main, Map<String, Uint8List> files) =>
    open(memoryDisc(main, {
      for (final e in files.entries) e.key: MemoryDiscFile(e.key, e.value)
    }));

Future<Uint8List> read(DiscImage image, int lba) async =>
    (await image.readSectors(lba, 1)).single;

/// each sector is filled with (file id + sector number) & 0xff
Uint8List makeBin(int sectors, {int id = 0}) {
  final data = Uint8List(sectors * size);
  for (int i = 0; i < sectors; i++) {
    data.fillRange(i * size, (i + 1) * size, (id + i) & 0xff);
  }
  return data;
}

/// 2048 bytes per sector, sector n is filled with n + 1
Uint8List cooked(int sectors) {
  final data = Uint8List(sectors * 2048);
  for (int i = 0; i < sectors; i++) {
    data.fillRange(i * 2048, (i + 1) * 2048, i + 1);
  }
  return data;
}

void main() {
  test('disc images are told by the extension', () {
    expect(DiscFileKind.of('a/Game.CUE'), DiscFileKind.image);
    expect(DiscFileKind.of('game.iso'), DiscFileKind.image);
    expect(DiscFileKind.of('game.bin'), DiscFileKind.maybeImage);
    expect(DiscFileKind.of('game.md'), DiscFileKind.notImage);
  });

  test('parse accepts walked files and resolves nested CUE paths in any order',
      () async {
    final directory = MemoryDirectory.of({
      'second/track.bin': makeBin(2, id: 42),
      'first/disc.cue': Uint8List.fromList(
          'FILE "TRACK.BIN" BINARY\n TRACK 01 MODE1/2352\n INDEX 01 00:00:00'
              .codeUnits),
      'second/disc.cue': Uint8List.fromList(
          'FILE "track.bin" BINARY\n TRACK 01 MODE1/2352\n INDEX 01 00:00:00'
              .codeUnits),
      'first/track.bin': makeBin(1, id: 7),
    });
    final files = directory.files.values.toList();
    final (first, firstFiles) = await DiscImage.parse(directory.files.values,
        files.singleWhere((file) => file.path == 'first/disc.cue'));
    final (second, secondFiles) = await DiscImage.parse(directory.files.values,
        files.singleWhere((file) => file.path == 'second/disc.cue'));
    expect((await first.readSectors(0, 1)).single[100], 7);
    expect((await second.readSectors(0, 1)).single[100], 42);
    expect(firstFiles.map((file) => file.path), ['first/track.bin']);
    expect(secondFiles.map((file) => file.path), ['second/track.bin']);
    expect(first.totalSectors, 1);
    expect(second.totalSectors, 2);
  });

  test(
      'factory returns distinct referenced files and no files for a standalone image',
      () async {
    final directory = MemoryDirectory.of({
      'disc.cue': Uint8List.fromList(('FILE "track.bin" BINARY\n'
              ' TRACK 01 MODE1/2352\n INDEX 01 00:00:00\n'
              'FILE "TRACK.BIN" BINARY\n'
              ' TRACK 02 AUDIO\n INDEX 01 00:00:00')
          .codeUnits),
      'track.bin': makeBin(2),
      'standalone.iso': Uint8List(2048),
    });
    final files = directory.files.values.toList();
    final (disc, referenced) =
        await DiscImage.parse(directory.files.values, files[0]);
    expect(disc.toc.tracks.length, 2);
    expect(referenced, [files[1]]);
    expect(await referenced.single.length(), size * 2);
    expect(() => referenced.clear(), throwsUnsupportedError);
    final (iso, isoFiles) =
        await DiscImage.parse(directory.files.values, files[2]);
    expect(iso.totalSectors, 1);
    expect(isoFiles, isEmpty);
  });

  test('missing references and invalid descriptions produce structured errors',
      () async {
    final directory = MemoryDirectory.of({
      'disc.cue': Uint8List.fromList(('FILE "missing.bin" BINARY\n'
              ' TRACK 01 MODE1/2352\n INDEX 01 00:00:00')
          .codeUnits),
      'invalid.cue': Uint8List.fromList('FILE "empty.bin" BINARY'.codeUnits),
    });
    final files = directory.files.values.toList();
    await expectLater(
        DiscImage.parse(directory.files.values, files[0]),
        throwsA(isA<DiscParseException>()
            .having((error) => error.imagePath, 'image path', 'disc.cue')
            .having(
                (error) => error.referencedPath, 'reference', 'missing.bin')));
    await expectLater(
        DiscImage.parse(directory.files.values, files[1]),
        throwsA(isA<DiscParseException>()
            .having((error) => error.imagePath, 'image path', 'invalid.cue')
            .having((error) => error.cause, 'cause', isA<FormatException>())));
  });

  test('malformed gap fields report parse errors rather than indexing errors',
      () async {
    for (final gap in ['PREGAP', 'POSTGAP']) {
      final directory = MemoryDirectory.of({
        'disc.cue': Uint8List.fromList(('FILE "track.bin" BINARY\n'
                ' TRACK 01 MODE1/2352\n $gap')
            .codeUnits),
        'track.bin': makeBin(1),
      });
      await expectLater(
          DiscImage.parse(directory.files.values, directory.files['disc.cue']!),
          throwsA(isA<DiscParseException>().having(
              (error) => error.cause, 'cause', isA<FormatException>())));
    }
  });

  group('cooked images', () {
    test('.iso of 2048 bytes/sector is expanded to raw mode 1 sectors',
        () async {
      final image = await insert("a.iso", {"a.iso": cooked(4)});
      expect(image.totalSectors, 4);

      final s = await read(image, 2);
      expect(s.length, size);
      expect(s.sublist(0, 12), ParsedDiscImage.sync);
      expect(s.sublist(12, 16), [0, 2, 2, 1]); // 00:02:02 mode 1
      expect(s.sublist(16, 16 + 2048).every((b) => b == 3), true);
    });

    test('a .bin with CD001 at sector 16 is cooked', () async {
      final data = cooked(20);
      data.setRange(16 * 2048 + 1, 16 * 2048 + 6, "CD001".codeUnits);
      final image = await insert("a.bin", {"a.bin": data});
      expect(image.totalSectors, 20);
      expect((await read(image, 0))[15], 1);
    });

    test('a raw image starting with the sync pattern is not cooked', () async {
      final raw = Uint8List(2352 * 4)..setRange(0, 12, ParsedDiscImage.sync);
      final image = await insert("a.iso", {"a.iso": raw});
      expect(image.totalSectors, 4);
      expect(await read(image, 0), raw.sublist(0, 2352));
    });

    test('cue: MODE1/2048 track', () async {
      final image = await insert("a.cue", {
        "a.cue": Uint8List.fromList('''
FILE "a.bin" BINARY
  TRACK 01 MODE1/2048
    INDEX 01 00:00:00
'''
            .codeUnits),
        "a.bin": cooked(5),
      });
      expect(image.totalSectors, 5);
      final s = await read(image, 4);
      expect(s.sublist(12, 16), [0, 2, 4, 1]); // 00:02:04 mode 1
      expect(s[16], 5);
    });
  });

  test('MODE1 track after stored audio pregap reads INDEX 01 payload',
      () async {
    final image = await insert("a.cue", {
      "a.cue": Uint8List.fromList('''
FILE "disc.bin" BINARY
  TRACK 01 AUDIO
    INDEX 01 00:00:00
  TRACK 02 MODE1/2352
    INDEX 00 00:00:02
    INDEX 01 00:00:04
'''
          .codeUnits),
      "disc.bin": makeBin(8),
    });
    expect(image.toc.tracks[1].startLba, 4);
    expect((await read(image, 4))[0], 4);
    expect((await read(image, 7))[0], 7);
    expect(image.isReadable(8), isFalse);
  });

  group('DiscImage', () {
    test('iso: single data track', () async {
      final image = await open(memoryDisc(
          "a.iso", {"a.iso": MemoryDiscFile("a.iso", makeBin(100))}));
      expect(image.toc.tracks.single.isAudio, false);
      expect(image.totalSectors, 100);
      expect(image.isReadable(99), true);
      expect(image.isReadable(100), false);
    });

    test('cue: single file with INDEX 00 and PREGAP', () async {
      const cue = '''
FILE "a.bin" BINARY
  TRACK 01 MODE2/2352
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    INDEX 00 00:01:00
    INDEX 01 00:01:10
  TRACK 03 AUDIO
    PREGAP 00:00:05
    INDEX 01 00:01:50
''';
      final image = await open(memoryDisc("a.cue", {
        "a.cue": MemoryDiscFile("a.cue", Uint8List.fromList(cue.codeUnits)),
        "a.bin": MemoryDiscFile("a.bin", makeBin(200)),
      }));
      final toc = image.toc;
      expect([for (final t in toc.tracks) t.startLba], [0, 85, 130]);
      expect([for (final t in toc.tracks) t.isAudio], [false, true, true]);
      expect(toc.totalSectors, 205);

      final segs = (image as ParsedDiscImage).segments(120, 20);
      expect([
        for (final s in segs) (s.lba, s.count, s.file != null, s.fileSector)
      ], [
        (120, 5, true, 120),
        (125, 5, false, 0),
        (130, 10, true, 125)
      ]);
    });

    test('cue: multiple files', () async {
      const cue = '''
FILE "t1.bin" BINARY
  TRACK 01 MODE2/2352
    INDEX 01 00:00:00
FILE "t2.bin" BINARY
  TRACK 02 AUDIO
    INDEX 00 00:00:00
    INDEX 01 00:02:00
''';
      final image = await open(memoryDisc("a.cue", {
        "a.cue": MemoryDiscFile("a.cue", Uint8List.fromList(cue.codeUnits)),
        "t1.bin": MemoryDiscFile("t1.bin", makeBin(300)),
        "t2.bin": MemoryDiscFile("t2.bin", makeBin(400)),
      }));
      expect([for (final t in image.toc.tracks) t.startLba], [0, 450]);
      expect([for (final t in image.toc.tracks) t.sectors], [450, 250]);
      expect(image.totalSectors, 700);
      final seg = (image as ParsedDiscImage).segments(450, 1).single;
      expect(seg.file!.path, "t2.bin");
      expect(seg.fileSector, 150);
    });
  });
}
