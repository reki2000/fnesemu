// writes the .bin/.cue of test/chd_fixture.dart into a directory; then make
// test/fixtures/small.chd by: chdman createcd -i DIR/small.cue -o small.chd
import 'dart:io';

import '../test/chd_fixture.dart';

void main(List<String> args) {
  final dir = Directory(args[0])..createSync(recursive: true);
  final bin = File('${dir.path}/small.bin').openSync(mode: FileMode.write);
  for (final s in fixtureSectors()) {
    bin.writeFromSync(s);
  }
  bin.closeSync();
  String msf(int lba) => [lba ~/ 4500, lba ~/ 75 % 60, lba % 75]
      .map((v) => v.toString().padLeft(2, '0'))
      .join(':');
  File('${dir.path}/small.cue').writeAsStringSync('''
FILE "small.bin" BINARY
  TRACK 01 MODE1/2352
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    INDEX 01 ${msf(dataSectors)}
''');
}
