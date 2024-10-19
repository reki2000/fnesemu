import 'dart:typed_data';

import 'pad.dart';
import 'rom.dart';

class BusM68 {
  BusM68();

  Rom rom = Rom();

  final pad = Pad();

  void onReset() {}

  final ram = Uint8List(0x1000000);

  int read(int addr) {
    addr &= 0xffffff;
    return ram[addr];
  }

  write(int addr, int data) {
    addr &= 0xffffff;
    ram[addr] = data;
  }

  int input(int port) {
    return 0xff;
  }

  void output(int port, int data) {}
}
