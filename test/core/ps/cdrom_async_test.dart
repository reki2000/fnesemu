import 'dart:typed_data';

import 'package:fnesemu/cdrom/async_cdrom_drive.dart';
import 'package:fnesemu/cdrom/image_file.dart';
import 'package:fnesemu/core/cdrom_drive.dart';
import 'package:fnesemu/core/disc.dart';
import 'package:fnesemu/core/memory_cdrom_drive.dart';
import 'package:fnesemu/core/ps/bus.dart';
import 'package:fnesemu/core/ps/cdrom.dart';
import 'package:test/test.dart';

class MemoryDisc extends Disc {
  final Uint8List data;
  MemoryDisc(this.data);

  @override
  Uint8List read(int sector) {
    final offset = (sector - 2 * 75) * Disc.sectorSize;
    return Uint8List.sublistView(data, offset, offset + Disc.sectorSize);
  }

  @override
  int get trackCount => 1;
  @override
  int get totalSectors => data.length ~/ Disc.sectorSize;
  @override
  int startLba(int trackNo) => 0;
  @override
  bool get isEmpty => false;
  @override
  bool isAudio(int trackNo) => false;
}

// run with: flutter test --dart-define=ASYNC_CDROM=true
void main() {
  group('async-cdrom', skip: asyncCdrom ? false : 'requires ASYNC_CDROM=true',
      () {
    _tests();
  });
}

void _tests() {
  late Cdrom cdrom;
  late AsyncCdromDrive drive;
  late List<int> irqs;
  late List<List<int>> results;

  Uint8List makeBin(int sectors) {
    final data = Uint8List(sectors * Disc.sectorSize);
    for (int i = 0; i < sectors; i++) {
      data.fillRange(i * Disc.sectorSize, (i + 1) * Disc.sectorSize, i & 0xff);
    }
    return data;
  }

  void command(int cmd, [List<int> params = const []]) {
    cdrom.writePort8(0, 0);
    for (final p in params) {
      cdrom.writePort8(2, p);
    }
    cdrom.writePort8(1, cmd);
  }

  /// runs the cdrom with the event loop until [until] returns true
  Future<void> run(bool Function() until, {int maxFrames = 600}) async {
    for (int frame = 0; frame < maxFrames && !until(); frame++) {
      for (int i = 0; i < 100 && !until(); i++) {
        cdrom.exec(5645); // 1/60s in 100 steps
        if (cdrom.currentIntNo != 0) {
          irqs.add(cdrom.currentIntNo);
          if (cdrom.currentIntNo == 1) {
            cdrom.writePort8(0, 0);
            cdrom.writePort8(3, 0x80); // request data
          } else {
            results.add(cdrom.resultFifo.toList());
            cdrom.resultFifo.clear();
          }
          cdrom.writePort8(0, 1);
          cdrom.writePort8(3, 0x07); // ack
        }
      }
      await Future.delayed(Duration.zero);
    }
  }

  setUp(() async {
    cdrom = Cdrom(Bus());
    drive = AsyncCdromDrive();
    irqs = [];
    results = [];
    cdrom.attachDrive(drive);
    await drive.eject(MemoryDiscSource(
        "a.bin", {"a.bin": MemoryImageFile("a.bin", makeBin(2000))}));
    cdrom.exec(1); // polls the drive
  });

  test('shell follows the drive', () async {
    expect(cdrom.isShellOpen, false);
    await drive.eject();
    cdrom.exec(1);
    expect(cdrom.isShellOpen, true);
  });

  test('eject during seek raises INT5', () async {
    command(0x02, [0x00, 0x20, 0x00]); // SetLoc 00:20:00
    command(0x15); // SeekL
    final ejected = drive.eject();
    await run(() => irqs.contains(5));
    await ejected;
    expect(irqs, [3, 3, 5]);
  });

  test('works with on-memory disc without the event loop', () {
    final disc = MemoryDisc(makeBin(100));
    cdrom.attachDrive(MemoryCdromDrive(disc));
    command(0x02, [0x00, 0x02, 0x05]); // SetLoc 00:02:05 => LBA 5
    command(0x06); // ReadN

    final read = <int>[];
    for (int i = 0; i < 100000 && read.length < 3; i++) {
      cdrom.exec(200);
      if (cdrom.currentIntNo == 1) {
        cdrom.writePort8(0, 0);
        cdrom.writePort8(3, 0x80);
        read.add(cdrom.readBuffer8());
        cdrom.writePort8(3, 0x00); // release the buffer
      }
      if (cdrom.currentIntNo != 0) {
        cdrom.writePort8(0, 1);
        cdrom.writePort8(3, 0x07);
      }
    }
    expect(read, [5, 6, 7]);
  });

  test('ReadN delivers sectors in order', () async {
    command(0x02, [0x00, 0x02, 0x10]); // SetLoc 00:02:10 => LBA 10
    command(0x06); // ReadN

    final read = <int>[];
    await run(() {
      if (irqs.isNotEmpty && irqs.last == 1 && !cdrom.sectorBufferEmpty) {
        read.add(cdrom.readBuffer8());
        cdrom.sectorBufferEmpty = true;
        irqs.add(0);
      }
      return read.length >= 100;
    });

    expect(read, List.generate(100, (i) => (10 + i) & 0xff));
  });

  test('SeekL raises INT2 after the drive completes the seek', () async {
    command(0x02, [0x00, 0x20, 0x00]); // SetLoc 00:20:00
    command(0x15); // SeekL
    expect(cdrom.isSeeking, true);
    await run(() => irqs.contains(2));
    expect(irqs, [3, 3, 2]); // SetLoc, SeekL, SeekL
    expect(cdrom.isSeeking, false);
  });

  test('SeekL out of the disc raises INT5', () async {
    command(0x02, [0x10, 0x00, 0x00]); // SetLoc 10:00:00
    command(0x15); // SeekL
    await run(() => irqs.contains(5));
    expect(irqs, [3, 3, 5]); // SetLoc, SeekL, SeekL error
    expect(results.last[0] & 0x05, 0x05); // error, seek error
  });

  test('GetTN uses TOC of the drive', () async {
    command(0x13);
    await run(() => irqs.contains(3));
    expect(results.single.sublist(1), [0x01, 0x01]); // first, last track
  });
}
