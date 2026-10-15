// Exercises the native filesystem disc adapter.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:cdrom_image/cdrom_image.dart';
import 'package:fnesemu_core/src/cdrom.dart';
import 'package:test/test.dart';

import '../../tool/cdrom_drive.dart';
import '../../tool/local_disc.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('cdrom_io_test_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('virtual files enumerate lazily and perform independent reads',
      () async {
    final sub = Directory('${dir.path}/nested')..createSync();
    final file = File('${sub.path}/track.bin')
      ..writeAsBytesSync(List.generate(100, (i) => i));
    final directory = localDiscFiles(dir.path);
    final walked = await directory.toList();
    expect(walked.single.path, 'nested/track.bin');
    final bytes = await Future.wait(
        [for (var i = 0; i < 30; i++) walked.single.read(i, 2)]);
    for (var i = 0; i < 30; i++) {
      expect(bytes[i], [i, i + 1]);
    }
    expect(await walked.single.length(), 100);
    expect(await walked.single.read(99, 10), [99]);
    await expectLater(walked.single.read(-1, 1), throwsA(anything));
    expect(await walked.single.read(0, 1), [0]);
    file.writeAsBytesSync([5, 6]);
    expect(await walked.single.length(), 2);
    expect(await walked.single.read(0, 5), [5, 6]);
  });

  test('parse uses directory files without caller-managed handles', () async {
    File('${dir.path}/disc.iso').writeAsBytesSync(Uint8List(2048 * 2));
    final files = await localDiscFiles(dir.path).toList();
    final (image, referenced) =
        await DiscImage.parse(files.single, files: files);
    expect(referenced, isEmpty);
    expect(image.totalSectors, 2);
    expect((await image.readSectors(1, 1)).single.length, 2352);
  });

  test('reads sectors of a cue disc from local files', () async {
    for (final (name, sectors, id) in [
      ("t1.bin", 300, 0),
      ("t2.bin", 200, 100)
    ]) {
      final data = Uint8List(sectors * cdSectorSize);
      for (int i = 0; i < sectors; i++) {
        data.fillRange(
            i * cdSectorSize, (i + 1) * cdSectorSize, (id + i) & 0xff);
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

    final drive = SimpleCdromDrive();
    await drive.insert(localDisc("${dir.path}/a.cue"));
    expect(drive.status.isReady, true);
    expect(drive.status.toc.startLba(2), 450);

    // concurrent reads over the files
    const lbas = [0, 299, 300, 450, 499, 100];
    final read = <int, int>{};
    while (read.length < lbas.length) {
      for (final lba in lbas) {
        final data = drive.read(lba);
        if (data != null) {
          read[lba] = data[100];
        }
      }
      await Future.delayed(const Duration(milliseconds: 1));
    }
    expect(read, {0: 0, 299: 43, 300: 100, 450: 250, 499: 43, 100: 100});

    await drive.eject();
  });
}
