import 'dart:typed_data';

import 'package:archive/archive.dart';
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

  test('a compressed ROM crossing deflate windows preserves every byte', () {
    final (data, name) = unpackRom(zipFixture('windowed'), 'game.zip');
    expect(name, 'game.ws');
    expect(data.length, 131072);
    expect(data, Uint8List.fromList(List.generate(
        131072, (i) => (i * 17 + (i >> 5) + (i >> 11)) & 255)));
  });

  test('an entry with an incorrect CRC is rejected before it can be loaded', () {
    final zip = zipFixture('windowed');
    final bytes = ByteData.sublistView(zip);
    for (var i = 0; i + 20 <= zip.length; i++) {
      if (bytes.getUint32(i, Endian.little) == 0x02014b50) {
        bytes.setUint32(i + 16, bytes.getUint32(i + 16, Endian.little) ^ 1, Endian.little);
        break;
      }
    }
    expect(() => unpackRom(zip, 'game.zip'), throwsA(isA<ArchiveChecksumException>()));
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
