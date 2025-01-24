import 'dart:typed_data';

import 'package:fnesemu/core/md/ym2612.dart';

import 'bus_m68.dart';
import 'sn76489.dart';
import 'z80/z80.dart';

class BusZ80 {
  late BusM68 busM68;
  late Z80 cpu;
  late Sn76489 psg;
  late Ym2612 ym2612;

  BusZ80();

  int _bank = 0x00; // shound not be 0x140 = 0xa00000
  final ram = Uint8List(0x2000);

  bool get busReq => cpu.halted;
  set busReq(bool value) {
    // print("z80 busreq:$value m68 pc:${busM68.cpu.pc.hex24}");
    cpu.halted = value;
  }

  bool _reset = false;
  set resetReq(bool value) {
    // print("z80 reset:$_reset->$value m68 pc:${busM68.cpu.pc.hex24}");
    if (value && !_reset) {
      cpu.reset(keepCycles: true); // reset when resetReq becomes up
    }
    _reset = value;
  }

  void onReset() {
    _bank = 0x00;
    _reset = false;
    cpu.reset();
  }

  int read(int addr) {
    if (addr < 0x4000) return ram[addr & 0x1fff]; // mirror of 0x0000-0x1fff

    if (addr < 0x6000) return ym2612.read8(0); // ym2612 a0

    if (addr >= 0x8000) {
      return busM68.read16(_bank | addr & 0x7fff) >> 8; // vdp & psg
    }

    if (addr & 0xff00 == 0x7f00) return busM68.read8(0xc00000 | addr & 0x1f);

    return 0xff;
  }

  write(int addr, int data) {
    // ram: 0x2000-0x3fff is a mirror of 0x0000-0x1fff
    if (addr < 0x4000) {
      ram[addr & 0x1fff] = data;
      return;
    }

    // ym2612: 0x4000-0x5fff
    if (addr < 0x6000) {
      switch (addr & 0x03) {
        case 0x00: // ym2612 a0
          ym2612.writePort8(0, data);
          return;
        case 0x01: // ym2612 d0
          ym2612.writeData8(0, data);
          return;
        case 0x02: // ym2612 a1
          ym2612.writePort8(1, data);
          return;
        case 0x03: // ym2612 d1
          ym2612.writeData8(1, data);
          return;
      }
    }

    // bank: 0x6000-0x60ff
    if (addr < 0x6100) {
      _bank = _bank >> 1 & 0x7f8000 | data << 23 & 0x800000;
      // print("bank: ${_bank.hex24}");
      return;
    }

    // 0x7f00-0x7f1f: vdp & psg
    if (addr & 0xff00 == 0x7f00) {
      busM68.write8(0xc00000 | addr & 0x1f, data);
      return;
    }

    // 0x8000-0xffff:  banked m68k address space
    if (addr >= 0x8000) {
      busM68.write8(_bank | addr & 0x7fff, data);
      return;
    }
  }

  int input(int port) {
    return 0xff;
  }

  void output(int port, int data) {}

  void interupt(int mode) {
    cpu.interrupt(mode);
  }
}
