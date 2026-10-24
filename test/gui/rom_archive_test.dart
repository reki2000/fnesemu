import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/gui/rom_archive.dart';

import 'zip_fixtures.dart';

void main() {
  test('a zip gives its first entry that a core recognizes', () {
    final rom = Uint8List.fromList(List.filled(0x8000, 1));
    final zip = zipFixture('rom');
    final (data, name) = unpackRom(zip, 'game.zip');
    expect(name, 'game.gb');
    expect(data, rom);
  });

  test('a file other than a zip is given as it is', () {
    final rom = Uint8List.fromList([1, 2, 3]);
    expect(unpackRom(rom, 'game.nes'), (rom, 'game.nes'));
  });

  test('a zip without a recognized ROM is rejected', () {
    final zip = zipFixture('notes');
    expect(() => unpackRom(zip, 'notes.zip'), throwsFormatException);
  });

  Future<List<String>> names(Uint8List zip) => zipEntryNames(
      zip.length,
      (offset, length) async =>
          Uint8List.sublistView(zip, offset, offset + length));

  test('the entry names are read from the central directory', () async {
    final zip = zipFixture('disc');
    expect(await names(zip), ['disc/game.cue', 'disc/game.bin']);
  });

  test('a zip of a CD-ROM image is not a ROM', () async {
    for (final image in ['cue', 'iso']) {
      final zip = zipFixture(image);
      expect(hasDiscImage(await names(zip)), isTrue);
      expect(() => unpackRom(zip, 'game.zip'), throwsFormatException);
    }
    final rom = zipFixture('gb');
    expect(hasDiscImage(await names(rom)), isFalse);
  });

  test('a file which is not a zip is rejected', () {
    expect(
        names(Uint8List.fromList(List.filled(100, 1))), throwsFormatException);
  });
}
