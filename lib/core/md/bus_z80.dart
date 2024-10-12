import 'dart:typed_data';

import 'pad.dart';
import 'rom.dart';

class BusZ80 {
  final ram = Uint8List(0x2000);

  BusZ80();

  Rom rom = Rom();

  final pad = Pad();

  void onReset() {}

  int read(int addr) {
    addr &= 0xffff;
    return addr < 0x2000 ? ram[addr] : 0xff;
  }

  write(int addr, int data) {
    addr &= 0xffff;
    if (addr < 0x2000) {
      ram[addr] = data;
    }
  }

  int input(int port) {
    return 0xff;
  }

  void output(int port, int data) {}
}
