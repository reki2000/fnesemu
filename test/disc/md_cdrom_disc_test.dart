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
