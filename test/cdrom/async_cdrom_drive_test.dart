import 'dart:async';
import 'dart:typed_data';

import 'package:fnesemu/cdrom/async_cdrom_drive.dart';
import 'package:fnesemu/cdrom/disc_layout.dart';
import 'package:fnesemu/cdrom/image_file.dart';
import 'package:fnesemu/core/cdrom_drive.dart';
import 'package:fnesemu/core/disc.dart';
import 'package:test/test.dart';

const size = Disc.sectorSize;

/// each sector is filled with (file id + sector number) & 0xff
Uint8List makeBin(int sectors, {int id = 0}) {
  final data = Uint8List(sectors * size);
  for (int i = 0; i < sectors; i++) {
    data.fillRange(i * size, (i + 1) * size, (id + i) & 0xff);
  }
  return data;
}

Future<void> pump() async {
  for (int i = 0; i < 10; i++) {
    await Future.delayed(Duration.zero);
  }
}

void main() {
  group('DiscLayout', () {
    test('iso: single data track', () async {
      final layout = await DiscLayout.build(MemoryDiscSource(
          "a.iso", {"a.iso": MemoryImageFile("a.iso", makeBin(100))}));
      expect(layout.toc.trackCount, 1);
      expect(layout.toc.isAudio(1), false);
      expect(layout.totalSectors, 100);
      expect(layout.isReadable(99), true);
      expect(layout.isReadable(100), false);
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
      final layout = await DiscLayout.build(MemoryDiscSource("a.cue", {
        "a.cue": MemoryImageFile("a.cue", Uint8List.fromList(cue.codeUnits)),
        "a.bin": MemoryImageFile("a.bin", makeBin(200)),
      }));
      final toc = layout.toc;
      expect(toc.trackCount, 3);
      expect([for (final t in toc.tracks) t.startLba], [0, 85, 130]);
      expect([for (final t in toc.tracks) t.isAudio], [false, true, true]);
      expect(toc.totalSectors, 205);
      expect(toc.isAudioLba(85), true);
      expect(toc.isAudioLba(84), false); // INDEX 00 belongs to track 1 in TOC
      expect(toc.isAudioLba(74), false);

      final segs = layout.segments(120, 20);
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
      final layout = await DiscLayout.build(MemoryDiscSource("a.cue", {
        "a.cue": MemoryImageFile("a.cue", Uint8List.fromList(cue.codeUnits)),
        "t1.bin": MemoryImageFile("t1.bin", makeBin(300)),
        "t2.bin": MemoryImageFile("t2.bin", makeBin(400)),
      }));
      expect([for (final t in layout.toc.tracks) t.startLba], [0, 450]);
      expect([for (final t in layout.toc.tracks) t.sectors], [450, 250]);
      expect(layout.totalSectors, 700);
      final seg = layout.segments(450, 1).single;
      expect(seg.file!.name, "t2.bin");
      expect(seg.fileSector, 150);
    });
  });

  group('AsyncCdromDrive', () {
    late MemoryImageFile bin;
    late List<(int, int)> fileReads;
    late AsyncCdromDrive drive;
    late DateTime now;

    setUp(() async {
      fileReads = [];
      bin = MemoryImageFile("a.bin", makeBin(1000))
        ..onRead =
            (offset, length) => fileReads.add((offset ~/ size, length ~/ size));
      now = DateTime(2026);
      drive = AsyncCdromDrive(now: () => now);
      await drive.eject(MemoryDiscSource("a.bin", {"a.bin": bin}));
    });

    test('reads TOC on insert', () async {
      expect(drive.status.isReady, true);
      expect(drive.status.toc.totalSectors, 1000);
      expect(fileReads, isEmpty); // no sector is read for an iso

      // disc id changes on each state change: trayOpen, loading, ready
      final id = drive.status.discId;
      final states = <CdromDriveState>[];
      final ejected = drive.eject(MemoryDiscSource("a.bin", {"a.bin": bin}));
      states.add(drive.status.state);
      await ejected;
      states.add(drive.status.state);
      expect(states, [CdromDriveState.trayOpen, CdromDriveState.ready]);
      expect(drive.status.discId, id + 3);
    });

    test('read returns null until the sector is read, with read-ahead',
        () async {
      expect(drive.read(10), isNull);
      await pump();

      expect(drive.read(10)![0], 10);
      expect(drive.read(10)!.length, size);
      expect(fileReads, [(10, AsyncCdromDrive.readAheadSectors + 1)]);
      expect(drive.cachedSectors, 76);

      // following sectors are read from the cache
      for (int s = 11; s < 40; s++) {
        expect(drive.read(s)![0], s);
      }
      expect(fileReads.length, 1);

      // read ahead when the half of the window is consumed
      expect(drive.read(50)![0], 50);
      expect(fileReads.length, 2);
      expect(fileReads[1], (86, 75));
      expect(drive.read(86), isNull);
      await pump();
      expect(drive.read(86)![0], 86);
    });

    test('repeated reads share the same file access', () async {
      expect(drive.read(0), isNull);
      expect(drive.read(1), isNull);
      expect(drive.read(0), isNull);
      await pump();
      expect(drive.read(0), isNotNull);
      expect(drive.read(1), isNotNull);
      expect(fileReads.length, 1);
    });

    test('cache expires after 60 seconds', () async {
      drive.read(0);
      await pump();
      expect(fileReads.length, 1);

      now = now.add(const Duration(seconds: 59));
      expect(drive.read(1), isNotNull);
      expect(fileReads.length, 1);

      now = now.add(const Duration(seconds: 2));
      expect(drive.read(2), isNull);
      await pump();
      expect(fileReads.length, 2);
      expect(fileReads[1].$1, 2);
      expect(drive.read(2)![0], 2);
    });

    test('out of range read returns empty data', () {
      expect(drive.read(1000), isEmpty);
      expect(drive.read(-1), isEmpty);
    });

    test('seek status', () async {
      drive.seek(500);
      expect(drive.status.isSeeking, true);
      expect(drive.status.seekError, false);
      await pump();
      expect(drive.status.isSeeking, false);
      expect(drive.status.seekError, false);
      expect(drive.status.seekLba, 500);
      expect(drive.read(500)![0], 500 & 0xff);

      drive.seek(2000);
      expect(drive.status.isSeeking, false);
      expect(drive.status.seekError, true);
    });

    test('read error is reported', () async {
      bin.onRead = (_, __) => throw Exception("broken");
      drive.seek(0);
      expect(drive.read(0), isNull);
      await pump();
      expect(drive.status.seekError, true);
      expect(drive.read(0), isEmpty);
    });

    test('eject discards pending reads', () async {
      drive.read(0);
      drive.seek(0);
      await drive.eject();
      await pump();
      expect(drive.status.state, CdromDriveState.empty);
      expect(drive.status.toc.isEmpty, true);
      expect(drive.status.isSeeking, false);
      expect(drive.cachedSectors, 0);
      expect(drive.read(0), isEmpty);
    });

    test('broken cue is reported as error', () async {
      await drive.eject(MemoryDiscSource("a.cue", {
        "a.cue": MemoryImageFile(
            "a.cue", Uint8List.fromList('FILE "x.bin" BINARY\n'.codeUnits)),
      }));
      expect(drive.status.state, CdromDriveState.error);
      expect(drive.status.isReady, false);
    });

    test('pregap sectors are silence', () async {
      const cue = '''
FILE "a.bin" BINARY
  TRACK 01 MODE2/2352
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    PREGAP 00:02:00
    INDEX 01 00:00:10
''';
      await drive.eject(MemoryDiscSource("a.cue", {
        "a.cue": MemoryImageFile("a.cue", Uint8List.fromList(cue.codeUnits)),
        "a.bin": MemoryImageFile("a.bin", makeBin(20, id: 1)),
      }));
      drive.read(9);
      await pump();
      expect(drive.read(9)![0], 10);
      expect(drive.read(10)!.every((b) => b == 0), true);
      drive.read(160);
      await pump();
      expect(drive.read(160)![0], 11);
    });
  });
}
