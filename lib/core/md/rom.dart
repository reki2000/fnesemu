import 'dart:developer';
import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';
import 'package:fnesemu/util/uint8list.dart';

class Rom {
  var rom = Uint8List(0);

  var ram = Uint8List(0);
  int ramStartAddr = 0;
  int ramEndAddr = 0; // exclusive

  Rom();

  void load(Uint8List body) {
    rom = body.buffer.asUint8List();

    if (rom.getUint16BE(0x1b0) == 0x5241 &&
        rom.getUint32BE(0x1b4) != 0x20202020) {
      ramStartAddr = rom.getUint32BE(0x1b4);
      ramEndAddr = rom.getUint32BE(0x1b8);
      ram = Uint8List.fromList(List.filled(ramEndAddr - ramStartAddr, 0xff));
    }

    log("loaded rom: ${rom.length.x6}, ram:${ramStartAddr.x6}-${ramEndAddr.x6}");
  }
}
