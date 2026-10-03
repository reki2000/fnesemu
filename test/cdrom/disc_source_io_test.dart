import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu/cdrom/async_cdrom_drive.dart';
import 'package:fnesemu/cdrom/disc_source_io.dart';
import 'package:fnesemu/core/cdrom_drive.dart';
import 'package:fnesemu/core/disc.dart';
import 'package:test/test.dart';

class _Listener implements CdromDriveListener {
  final sectors = <int, Uint8List>{};

  @override
  void onDiscChanged(CdromDriveStatus status) {}

  @override
  void onSeekComplete(int lba, bool ok) {}

  @override
  void onSectorRead(int lba, Uint8List data) => sectors[lba] = data;
}

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('cdrom_io_test_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('reads sectors of a cue disc from local files', () async {
    for (final (name, sectors, id) in [
      ("t1.bin", 300, 0),
      ("t2.bin", 200, 100)
    ]) {
      final data = Uint8List(sectors * Disc.sectorSize);
      for (int i = 0; i < sectors; i++) {
        data.fillRange(
            i * Disc.sectorSize, (i + 1) * Disc.sectorSize, (id + i) & 0xff);
      }
      File("${dir.path}/$name").writeAsBytesSync(data);
    }
    File("${dir.path}/a.cue").writeAsStringSync('''
FILE "t1.bin" BINARY
  TRACK 01 MODE2/2352
    INDEX 01 00:00:00
FILE "t2.bin" BINARY
  TRACK 02 AUDIO
    INDEX 00 00:00:00
    INDEX 01 00:02:00
''');

    final listener = _Listener();
    final drive = AsyncCdromDrive()..listener = listener;
    await drive.eject(discSourceFromPath("${dir.path}/a.cue"));
    expect(drive.status.isReady, true);
    expect(drive.status.toc.startLba(2), 450);

    // concurrent reads over the files
    for (final lba in [0, 299, 300, 450, 499, 100]) {
      drive.read(lba);
    }
    while (listener.sectors.length < 6) {
      await Future.delayed(const Duration(milliseconds: 1));
    }
    expect({for (final e in listener.sectors.entries) e.key: e.value[100]},
        {0: 0, 299: 43, 300: 100, 450: 250, 499: 43, 100: 100});

    await drive.eject();
  });
}
