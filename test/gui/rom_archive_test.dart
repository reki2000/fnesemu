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
    final zip = Uint8List.fromList(ZipEncoder().encode(archive)!);
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
    final zip = Uint8List.fromList(ZipEncoder().encode(archive)!);
    expect(() => unpackRom(zip, 'notes.zip'), throwsFormatException);
  });
}
