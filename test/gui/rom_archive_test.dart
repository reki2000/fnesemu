import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/gui/rom_archive.dart';

void main() {
  test('a zip gives its first entry that a core recognizes', () {
    final rom = Uint8List.fromList(List.filled(0x8000, 1));
    final archive = Archive()
      ..addFile(ArchiveFile('readme.txt', 5, 'hello'.codeUnits))
      ..addFile(ArchiveFile('game.gb', rom.length, rom));
    final zip = Uint8List.fromList(ZipEncoder().encode(archive));
    final (data, name) = unpackRom(zip, 'game.zip');
    expect(name, 'game.gb');
    expect(data, rom);
  });

  test('a file other than a zip is given as it is', () {
    final rom = Uint8List.fromList([1, 2, 3]);
    expect(unpackRom(rom, 'game.nes'), (rom, 'game.nes'));
  });

  test('a zip without a recognized ROM is rejected', () {
    final archive = Archive()
      ..addFile(ArchiveFile('readme.txt', 5, 'hello'.codeUnits));
    final zip = Uint8List.fromList(ZipEncoder().encode(archive));
    expect(() => unpackRom(zip, 'notes.zip'), throwsFormatException);
  });

  Uint8List zipOf(Map<String, List<int>> files, {String? comment}) {
    final archive = Archive();
    for (final e in files.entries) {
      archive.addFile(ArchiveFile(e.key, e.value.length, e.value));
    }
    if (comment != null) archive.comment = comment;
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  Future<List<String>> names(Uint8List zip) => zipEntryNames(
      zip.length,
      (offset, length) async =>
          Uint8List.sublistView(zip, offset, offset + length));

  test('the entry names are read from the central directory', () async {
    final zip = zipOf({
      'disc/game.cue': 'FILE'.codeUnits,
      'disc/game.bin': List.filled(4096, 7),
    }, comment: 'a comment');
    expect(await names(zip), ['disc/game.cue', 'disc/game.bin']);
  });

  test('a zip of a CD-ROM image is not a ROM', () async {
    for (final image in ['game.cue', 'game.iso']) {
      final zip = zipOf({image: [1], 'game.bin': List.filled(0x8000, 1)});
      expect(hasDiscImage(await names(zip)), isTrue);
      expect(() => unpackRom(zip, 'game.zip'), throwsFormatException);
    }
    final rom = zipOf({'game.gb': List.filled(0x8000, 1)});
    expect(hasDiscImage(await names(rom)), isFalse);
  });

  test('a file which is not a zip is rejected', () {
    expect(
        names(Uint8List.fromList(List.filled(100, 1))), throwsFormatException);
  });
}
