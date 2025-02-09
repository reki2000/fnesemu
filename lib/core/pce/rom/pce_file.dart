// Dart imports:
import 'dart:typed_data';

// Project imports:
import 'package:archive/archive_io.dart';

import '../../../util/util.dart';

class PceFile {
  final banks = List<Uint8List>.filled(0, Uint8List(0), growable: true);
  late final String crc;

  /// throws exception when load failed
  void load(Uint8List body) {
    // caclurate CRC32 of entire file
    crc = (Crc32()..add(body.toList())).close().map((val) => hex8(val)).join();
    // load rom data
    const bankSize = 8 * 1024;

    final hasHeader = body.sublist(16, 200).every((e) => e == 0);
    body = body.sublist(hasHeader ? 0x200 : 0); // skip header

    int offset = 0;
    while (offset + bankSize < body.length) {
      banks.add(body.sublist(offset, offset + bankSize));
      offset += bankSize;
    }

    if (offset < body.length) {
      // Create a new Uint8List of length bankSize and copy the remaining bytes into it
      Uint8List padded = Uint8List(bankSize);
      Uint8List remining = body.sublist(offset);
      for (int i = 0; i < remining.length; i++) {
        padded[i] = remining[i];
      }
      banks.add(padded);
    }
  }
}
