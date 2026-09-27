import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu/core/disc.dart';
import 'package:fnesemu/disc/cue.dart';
import 'package:fnesemu/disc/iso.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('md_cdrom_disc_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('cooked ISO expands all sectors including the last one', () {
    final data = Uint8List(4096)
      ..[0] = 0x12
      ..[2048] = 0x34;
    final file = File('${dir.path}/game.iso')..writeAsBytesSync(data);
    final disc = IsoDisc(file.path);
    expect(disc.totalSectors, 2);
    expect(disc.read(149), isEmpty);
    expect(disc.read(150).sublist(0, 12), Disc.sync);
    expect(disc.read(150).sublist(12, 17), [0, 2, 0, 1, 0x12]);
    expect(disc.read(151)[16], 0x34);
    expect(disc.read(152), isEmpty);
  });

  test('raw BIN retains the last sector without modifying its data', () {
    final raw = Uint8List(2352)..[16] = 0xab;
    final file = File('${dir.path}/game.bin')..writeAsBytesSync(raw);
    final disc = IsoDisc(file.path);
    expect(disc.totalSectors, 1);
    expect(disc.read(150), raw);
    expect(disc.read(151), isEmpty);
  });

  test('raw Mode 1 ISO is recognized by its sync header', () {
    final raw = Disc.mode1Sector(Uint8List(2048)..[0] = 0x55, 0);
    final file = File('${dir.path}/game.iso')..writeAsBytesSync(raw);
    expect(IsoDisc(file.path).read(150), raw);
  });

  test('implicit PREGAP adds silence without skipping file data', () {
    final data = Uint8List(2352)..[0] = 42;
    File('${dir.path}/disc.img').writeAsBytesSync(data);
    final cue = File('${dir.path}/game.cue')..writeAsStringSync('''
FILE "disc.img" BINARY
 TRACK 01 MODE1/2352
  PREGAP 00:02:00
  INDEX 01 00:00:00
''');
    final disc = CueDisc(cue.path);
    expect(disc.startLba(1), 150);
    expect(disc.totalSectors, 151);
    expect(disc.read(299), isEmpty);
    expect(disc.read(300), data);
  });

  test('shared image INDEX 00 gaps do not shift audio data or inflate length',
      () {
    final data = Uint8List(10 * 2352);
    for (int sector = 0; sector < 10; sector++) {
      data[sector * 2352] = sector;
    }
    File('${dir.path}/disc.img').writeAsBytesSync(data);
    final cue = File('${dir.path}/game.cue')..writeAsStringSync('''
FILE "disc.img" BINARY
 TRACK 01 MODE1/2352
  INDEX 01 00:00:00
 TRACK 02 AUDIO
  INDEX 00 00:00:03
  INDEX 01 00:00:05
 TRACK 03 AUDIO
  INDEX 00 00:00:07
  INDEX 01 00:00:08
''');
    final disc = CueDisc(cue.path);
    expect(disc.totalSectors, 10);
    expect(disc.startLba(2), 5);
    expect(disc.startLba(3), 8);
    expect(disc.read(153), isEmpty);
    expect(disc.read(155)[0], 5);
    expect(disc.read(158)[0], 8);
    expect(disc.read(159)[0], 9);
    expect(disc.read(160), isEmpty);
  });

  test('CUE supports separate cooked data and raw audio files', () {
    File('${dir.path}/data.iso')
        .writeAsBytesSync(Uint8List(4096)..[2048] = 0x42);
    final audio = Uint8List(2352)..[0] = 0x11;
    File('${dir.path}/audio.bin').writeAsBytesSync(audio);
    final cue = File('${dir.path}/game.cue')..writeAsStringSync('''
FILE "data.iso" BINARY
 TRACK 01 MODE1/2048
  INDEX 01 00:00:00
FILE "audio.bin" BINARY
 TRACK 02 AUDIO
  INDEX 01 00:00:00
''');
    final disc = CueDisc(cue.path);
    expect(disc.trackCount, 2);
    expect(disc.totalSectors, 3);
    expect(disc.startLba(2), 2);
    expect(disc.read(151)[16], 0x42);
    expect(disc.read(152), audio);
    expect(disc.isAudioSector(150), isFalse);
    expect(disc.isAudioSector(151), isFalse);
    expect(disc.isAudioSector(152), isTrue);
    expect(disc.isAudioSector(153), isFalse);
  });
}
