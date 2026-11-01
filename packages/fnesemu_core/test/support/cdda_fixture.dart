import 'dart:typed_data';

import 'fake_cdrom_drive.dart';

FakeCdromDrive cddaRampDrive(int sectors) => FakeCdromDrive([
      for (var sector = 0; sector < sectors; sector++)
        () {
          final bytes = ByteData(2352);
          for (var frame = 0; frame < 588; frame++) {
            final value = sector * 588 + frame;
            bytes.setInt16(frame * 4, value, Endian.little);
            bytes.setInt16(frame * 4 + 2, -value, Endian.little);
          }
          return bytes.buffer.asUint8List();
        }(),
    ], audioTracks: {
      1
    });
