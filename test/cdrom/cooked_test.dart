import 'dart:typed_data';

import 'package:fnesemu/cdrom/async_cdrom_drive.dart';
import 'package:fnesemu/cdrom/image_file.dart';
import 'package:fnesemu/core/disc.dart';
import 'package:test/test.dart';

Future<AsyncCdromDrive> insert(String main, Map<String, Uint8List> files) async {
  final drive = AsyncCdromDrive();
  await drive.insert(MemoryDiscSource(main, {
    for (final e in files.entries) e.key: MemoryImageFile(e.key, e.value)
  }));
  return drive;
}

Future<Uint8List> read(AsyncCdromDrive drive, int lba) async {
  var sector = drive.read(lba);
  if (sector == null) {
    await drive.settle();
    sector = drive.read(lba);
  }
  return sector!;
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
  group('cooked images', () {
    test('.iso of 2048 bytes/sector is expanded to raw mode 1 sectors',
        () async {
      final drive = await insert("a.iso", {"a.iso": cooked(4)});
      expect(drive.status.toc.totalSectors, 4);

      final s = await read(drive, 2);
      expect(s.length, Disc.sectorSize);
      expect(s.sublist(0, 12), Disc.sync);
      expect(s.sublist(12, 16), [0, 2, 2, 1]); // 00:02:02 mode 1
      expect(s.sublist(16, 16 + 2048).every((b) => b == 3), true);
    });

    test('a .bin with CD001 at sector 16 is cooked', () async {
      final data = cooked(20);
      data.setRange(16 * 2048 + 1, 16 * 2048 + 6, "CD001".codeUnits);
      final drive = await insert("a.bin", {"a.bin": data});
      expect(drive.status.toc.totalSectors, 20);
      expect((await read(drive, 0))[15], 1);
    });

    test('a raw image starting with the sync pattern is not cooked', () async {
      final raw = Uint8List(2352 * 4)..setRange(0, 12, Disc.sync);
      final drive = await insert("a.iso", {"a.iso": raw});
      expect(drive.status.toc.totalSectors, 4);
      expect(await read(drive, 0), raw.sublist(0, 2352));
    });

    test('cue: MODE1/2048 track', () async {
      final drive = await insert("a.cue", {
        "a.cue": Uint8List.fromList('''
FILE "a.bin" BINARY
  TRACK 01 MODE1/2048
    INDEX 01 00:00:00
'''
            .codeUnits),
        "a.bin": cooked(5),
      });
      expect(drive.status.toc.totalSectors, 5);
      final s = await read(drive, 4);
      expect(s.sublist(12, 16), [0, 2, 4, 1]); // 00:02:04 mode 1
      expect(s[16], 5);
    });
  });

  test('MODE1 track after stored audio pregap reads INDEX 01 payload',
      () async {
    final image = Uint8List(8 * Disc.sectorSize);
    for (var i = 0; i < 8; i++) {
      image.fillRange(i * Disc.sectorSize, (i + 1) * Disc.sectorSize, i);
    }
    final drive = await insert("a.cue", {
      "a.cue": Uint8List.fromList('''
FILE "disc.bin" BINARY
  TRACK 01 AUDIO
    INDEX 01 00:00:00
  TRACK 02 MODE1/2352
    INDEX 00 00:00:02
    INDEX 01 00:00:04
'''
          .codeUnits),
      "disc.bin": image,
    });
    expect(drive.status.toc.startLba(2), 4);
    expect((await read(drive, 4))[0], 4);
    expect((await read(drive, 7))[0], 7);
    expect(await read(drive, 8), isEmpty);
  });

  test('Disc reads with absolute sectors and null while pending', () async {
    final drive = await insert("a.iso", {"a.iso": cooked(4)});
    final disc = Disc(drive);
    expect(disc.isEmpty, false);
    expect(disc.totalSectors, 4);
    expect(disc.read(150 + 1), isNull);
    await drive.settle();
    expect(disc.read(150 + 1)![16], 2);
    expect(disc.read(149), isEmpty);
    expect(Disc.empty().isEmpty, true);
  });
}
