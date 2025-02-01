import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';
import 'package:fnesemu/util/util.dart';

class Rom {
  var rom = Uint8List(0);

  var ram = Uint8List(0);
  int ramStartAddr = 0;
  int ramEndAddr = 0; // exclusive

  Rom();

  void load(Uint8List body) {
    rom = body.buffer.asUint8List();

    if (rom.getUInt16BE(0x1b0) == 0x5241 &&
        rom.getUInt32BE(0x1b4) != 0x20202020) {
      ramStartAddr = rom.getUInt32BE(0x1b4);
      ramEndAddr = rom.getUInt32BE(0x1b8);
      ram = Uint8List.fromList(List.filled(ramEndAddr - ramStartAddr, 0xff));
    }

    print(
        "loaded rom: ${rom.length.hex24}, ram:${ramStartAddr.hex24}-${ramEndAddr.hex24}");
  }
}
