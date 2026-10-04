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

  // SSF mapper: a rom larger than 4MiB is seen through 8 slots of 512KiB.
  // slot 0 is fixed, the registers $a130f3-$a130ff select the bank of slot 1-7
  final bank = List<int>.generate(8, (i) => i);
  bool get banked => rom.length > 0x400000;

  int mapOffset(int offset) =>
      banked ? (bank[offset >> 19] << 19) | (offset & 0x7ffff) : offset;

  // addr: $a130f0-$a130ff
  void writeBankRegister(int addr, int data) {
    final slot = (addr & 0x0f) >> 1;
    if (slot > 0) {
      bank[slot] = data & 0x3f;
    }
  }

  void load(Uint8List body) {
    rom = body.buffer.asUint8List();
    for (int i = 0; i < 8; i++) {
      bank[i] = i;
    }

    if (rom.getUint16BE(0x1b0) == 0x5241 &&
        rom.getUint32BE(0x1b4) != 0x20202020) {
      ramStartAddr = rom.getUint32BE(0x1b4);
      ramEndAddr = rom.getUint32BE(0x1b8);
      ram = Uint8List.fromList(List.filled(ramEndAddr - ramStartAddr, 0xff));
    }

    log("loaded rom: ${rom.length.x6}, ram:${ramStartAddr.x6}-${ramEndAddr.x6}");
  }
}
