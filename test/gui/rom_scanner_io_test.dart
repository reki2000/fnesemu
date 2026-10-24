// Exercises real files and directories.
@TestOn('vm')
library;

import 'dart:io';

import 'package:cdrom_image/cdrom_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/gui/rom_scanner.dart';
import 'package:mp_bigfile_picker/io.dart';

import 'rom_scanner_test.dart' show bin, cue;

void main() {
  test('a local directory lists the files recursively', () async {
    final dir = Directory.systemTemp.createTempSync('scan_test_');
    addTearDown(() => dir.deleteSync(recursive: true));
    Directory('${dir.path}/a/b').createSync(recursive: true);
    File('${dir.path}/a/b/x.cue').writeAsStringSync(cue(["x.bin"]));
    File('${dir.path}/a/b/x.bin').writeAsBytesSync(bin);
    File('${dir.path}/y.iso').writeAsBytesSync(bin);

    final r = await RomScanner.scan(IoDirectory(dir.path));
    expect(r.items.map((i) => i.path), ["a/b/x.cue", "y.iso"]);

    final (file, files) = r.sourceOf(r.items.first);
    final (image, _) = await DiscImage.parse(file, files: files);
    expect(image.totalSectors, 4);
  });
}
