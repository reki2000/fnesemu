import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';

import 'pad.dart';
import 'rom.dart';

class BusM68 {
  BusM68();

  Rom rom = Rom();

  final pad = Pad();

  void onReset() {}

  final ram = Uint8List(0x10000);
  final ramZ80 = Uint8List(0x10000);

  int read(int addr) {
    final top = addr >> 16 & 0xff;
    if (top < 0x40) {
      final offset = addr & 0x3fffff;
      // print(
      //     "read: ${addr.hex32} ${top.hex8} ${offset.hex32} l:${rom.rom.length} data:${offset < rom.rom.length ? rom.rom[offset].hex8 : "-"}");
      if (offset < rom.rom.length) {
        return rom.rom[offset];
      } else {
        return 0x00;
      }
    }

    if (top == 0xff) {
      return ram[addr.mask16];
    }

    if (top == 0xa0) {
      return ramZ80[addr.mask16];
    }

    return 0xff;
  }

  write(int addr, int data) {
    final top = addr >> 16 & 0xff;

    if (top == 0xff) {
      ram[addr.mask16] = data;
    }

    if (top == 0xa0) {
      ramZ80[addr.mask16] = data;
    }
  }

  int input(int port) {
    return 0xff;
  }

  void output(int port, int data) {}
}
