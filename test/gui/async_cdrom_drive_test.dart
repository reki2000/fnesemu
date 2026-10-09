import 'dart:typed_data';

import 'package:cdrom/cdrom.dart';
import 'package:cdrom/memory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/gui/async_cdrom_drive.dart';
import 'package:fnesemu_core/core/disc.dart';

/// each sector is filled with its sector number
Uint8List makeBin(int sectors) {
  const size = DiscImage.sectorSize;
  final data = Uint8List(sectors * size);
  for (int i = 0; i < sectors; i++) {
    data.fillRange(i * size, (i + 1) * size, i & 0xff);
  }
  return data;
}

void main() {
  test('the TOC of the image is given to the core', () async {
    const cue = '''
FILE "a.bin" BINARY
  TRACK 01 MODE2/2352
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    INDEX 00 00:01:00
    INDEX 01 00:01:10
''';
    final drive = AsyncCdromDrive();
    await drive.insert(memoryDisc("a.cue", {
      "a.cue": MemoryDiscFile("a.cue", Uint8List.fromList(cue.codeUnits)),
      "a.bin": MemoryDiscFile("a.bin", makeBin(200)),
    }));
    final toc = drive.status.toc;
    expect(toc.trackCount, 2);
    expect(toc.startLba(2), 85);
    expect(toc.totalSectors, 200);
    expect(toc.isAudioLba(85), true);
    expect(toc.isAudioLba(84), false); // INDEX 00 belongs to track 1 in TOC
  });

  test('Disc reads with absolute sectors and null while pending', () async {
    final drive = AsyncCdromDrive();
    await drive.insert(
        memoryDisc("a.bin", {"a.bin": MemoryDiscFile("a.bin", makeBin(4))}));
    final disc = Disc(drive);
    expect(disc.isEmpty, false);
    expect(disc.totalSectors, 4);
    expect(disc.read(150 + 1), isNull);
    await drive.settle();
    expect(disc.read(150 + 1)![16], 1);
    expect(disc.read(149), isEmpty);
    expect(Disc.empty().isEmpty, true);
  });

  test('the status is converted only when it changes', () async {
    final drive = AsyncCdromDrive();
    expect(identical(drive.status, drive.status), true);
    await drive.insert(
        memoryDisc("a.bin", {"a.bin": MemoryDiscFile("a.bin", makeBin(4))}));
    final ready = drive.status;
    expect(ready.isReady, true);
    expect(identical(drive.status, ready), true);
    await drive.eject();
    expect(drive.status.isTrayOpen, true);
    expect(drive.status.toc.isEmpty, true);
  });
}
