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

class Listener implements CdromDriveListener {
  final changes = <CdromDriveState>[];
  final seeks = <(int, bool)>[];
  final sectors = <int, Uint8List>{};

  @override
  void onDiscChanged(CdromDriveStatus status) => changes.add(status.state);

  @override
  void onSeekComplete(int lba, bool ok) => seeks.add((lba, ok));

  @override
  void onSectorRead(int lba, Uint8List data) => sectors[lba] = data;
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
    late Listener listener;
    late AsyncCdromDrive drive;
    late DateTime now;

    setUp(() async {
      fileReads = [];
      bin = MemoryImageFile("a.bin", makeBin(1000))
        ..onRead =
            (offset, length) => fileReads.add((offset ~/ size, length ~/ size));
      listener = Listener();
      now = DateTime(2026);
      drive = AsyncCdromDrive(now: () => now)..listener = listener;
      await drive.eject(MemoryDiscSource("a.bin", {"a.bin": bin}));
    });

    test('reads TOC on insert and notifies the core', () {
      expect(listener.changes, [
        CdromDriveState.trayOpen,
        CdromDriveState.loading,
        CdromDriveState.ready
      ]);
      expect(drive.status.isReady, true);
      expect(drive.status.toc.totalSectors, 1000);
      expect(fileReads, isEmpty); // no sector is read for an iso
    });

    test('read is notified asynchronously with read-ahead', () async {
      drive.read(10);
      expect(listener.sectors, isEmpty); // not synchronously
      await pump();

      expect(listener.sectors[10]![0], 10);
      expect(listener.sectors[10]!.length, size);
      expect(fileReads, [(10, AsyncCdromDrive.readAheadSectors + 1)]);
      expect(drive.cachedSectors, 76);

      // following sectors are read from the cache
      for (int s = 11; s < 40; s++) {
        drive.read(s);
      }
      await pump();
      expect(listener.sectors[39]![0], 39);
      expect(fileReads.length, 1);

      // read ahead when the half of the window is consumed
      drive.read(50);
      await pump();
      expect(fileReads.length, 2);
      expect(fileReads[1], (86, 75));
    });

    test('concurrent reads share the same file access', () async {
      drive.read(0);
      drive.read(1);
      drive.read(2);
      await pump();
      expect(listener.sectors.keys, containsAll([0, 1, 2]));
      expect(fileReads.length, 1);
    });

    test('cache expires after 60 seconds', () async {
      drive.read(0);
      await pump();
      expect(fileReads.length, 1);

      now = now.add(const Duration(seconds: 59));
      drive.read(1);
      await pump();
      expect(fileReads.length, 1);

      now = now.add(const Duration(seconds: 2));
      drive.read(2);
      await pump();
      expect(fileReads.length, 2);
      expect(fileReads[1].$1, 2);
    });

    test('out of range read returns empty data', () async {
      drive.read(1000);
      drive.read(-1);
      await pump();
      expect(listener.sectors[1000], isEmpty);
      expect(listener.sectors[-1], isEmpty);
    });

    test('seek completes after the sector is loaded', () async {
      drive.seek(500);
      expect(drive.status.isSeeking, true);
      expect(listener.seeks, isEmpty);
      await pump();
      expect(listener.seeks, [(500, true)]);
      expect(drive.status.isSeeking, false);
      expect(drive.status.headLba, 500);

      drive.seek(2000);
      await pump();
      expect(listener.seeks.last, (2000, false));
    });

    test('eject discards pending reads and notifies the core', () async {
      drive.read(0);
      final ejected = drive.eject();
      await ejected;
      await pump();
      expect(listener.sectors, isEmpty);
      expect(listener.changes.last, CdromDriveState.empty);
      expect(drive.status.toc.isEmpty, true);
      expect(drive.cachedSectors, 0);

      drive.read(0);
      await pump();
      expect(listener.sectors[0], isEmpty);
    });

    test('broken cue is reported as error', () async {
      await drive.eject(MemoryDiscSource("a.cue", {
        "a.cue": MemoryImageFile(
            "a.cue", Uint8List.fromList('FILE "x.bin" BINARY\n'.codeUnits)),
      }));
      expect(listener.changes.last, CdromDriveState.error);
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
      drive.read(10);
      drive.read(160);
      await pump();
      expect(listener.sectors[9]![0], 10);
      expect(listener.sectors[10]!.every((b) => b == 0), true);
      expect(listener.sectors[160]![0], 11);
    });
  });
}
