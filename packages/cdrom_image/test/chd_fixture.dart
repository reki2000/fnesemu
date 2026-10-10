// the disc of test/fixtures/small.chd, made by tool/make_chd_fixture.dart and
// chdman 0.242: a data track of 40 mode 1 sectors and an audio track of 40
// sectors (chdman makes a broken map for a few hunks, e.g. 24 sectors)
import 'dart:math';
import 'dart:typed_data';

import 'package:cdrom_image/format/chd/cd_ecc.dart';

const dataSectors = 40, audioSectors = 40;

/// the raw sectors (audio in little-endian, as in a .bin)
List<Uint8List> fixtureSectors() {
  final random = Random(42);
  int bcd(int v) => ((v ~/ 10) << 4) | (v % 10);
  return [
    for (int lba = 0; lba < dataSectors; lba++)
      () {
        final s = Uint8List(2352)
          ..setAll(0, [0, ...List.filled(10, 0xff), 0])
          ..setAll(12, [
            bcd((lba + 150) ~/ 4500),
            bcd((lba + 150) ~/ 75 % 60),
            bcd((lba + 150) % 75),
            1
          ]);
        for (int i = 16; i < 16 + 2048; i++) {
          // compressible: runs of a few values
          s[i] = i % 64 < 40 ? (lba * 7 + i ~/ 64) & 0xff : random.nextInt(4);
        }
        generateEcc(s);
        return s;
      }(),
    for (int i = 0; i < audioSectors; i++)
      () {
        final s = Uint8List(2352);
        if (i < 13) {
          final v = ByteData.sublistView(s);
          for (int k = 0; k < 588; k++) {
            final t = i * 588 + k;
            v.setInt16(k * 4, (9000 * sin(t * 0.05)).round(), Endian.little);
            v.setInt16(
                k * 4 + 2, (7000 * sin(t * 0.031)).round(), Endian.little);
          }
        }
        return s;
      }(),
  ];
}
