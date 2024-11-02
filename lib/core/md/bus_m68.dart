import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';

import 'bus_z80.dart';
import 'm68/m68.dart';
import 'pad.dart';
import 'psg.dart';
import 'rom.dart';
import 'vdp.dart';

class BusM68 {
  BusM68();

  late BusZ80 busZ80;
  late M68 cpu;
  late Vdp vdp;
  late Psg psg;

  Rom rom = Rom();

  final pad = Pad();

  void onReset() {
    cpu.reset();
    vdp.reset();
    psg.reset();
  }

  final ram = Uint8List(0x10000);

  int read8(int addr) {
    final top = addr >> 16 & 0xff;

    if (top < 0x40) {
      final offset = addr & 0x3fffff;

      if (offset < rom.rom.length) {
        return rom.rom[offset];
      }

      return 0x00;
    }

    if (top == 0xff) {
      return ram[addr.mask16];
    }

    if (top == 0xc0) {
      if (addr & 0x10 == 0x10) {
        return psg.read8(addr.mask16);
      }
    }

    if (top == 0xa1) {}

    if (top == 0xa0 && busZ80.busreq) {
      return addr < 0xa08000 ? busZ80.read(addr.mask16) : 0x00;
    }

    return 0xff;
  }

  int read16(int addr) {
    final top = addr >> 16 & 0xff;

    if (top < 0x40) {
      final offset = addr & 0x3fffff;

      if (offset < rom.rom.length - 1) {
        return rom.rom[offset] << 8 | rom.rom[offset.inc];
      }

      return 0x00;
    }

    if (top == 0xff) {
      return ram[addr.mask16] << 8 | ram[addr.inc.mask16];
    }

    if (top == 0xc0) {
      if (addr & 0x1e == 0x10) {
        return psg.read8(addr.mask16) << 8 | psg.read8(addr.inc.mask16);
      }

      return vdp.read16(addr.mask16);
    }

    if (top == 0xa1) {
      return readIo16(addr);
    }

    if (top == 0xa0 && busZ80.busreq) {
      return addr < 0xa08000
          ? busZ80.read(addr.mask16) << 8 | busZ80.read(addr.inc.mask16)
          : 0x00;
    }

    return 0xff;
  }

  write8(int addr, int data) {
    final top = addr >> 16 & 0xff;

    if (top == 0xff) {
      ram[addr.mask16] = data;
    }

    if (top == 0xc0) {
      if (addr & 0x1e == 0x10) {
        psg.write8(addr, data);
      }
    }

    if (top == 0xa1) {}

    if (top == 0xa0 && busZ80.busreq) {
      busZ80.write(addr.mask16, data);
    }
  }

  write16(int addr, int data) {
    final top = addr >> 16 & 0xff;

    if (top == 0xff) {
      ram[addr.mask16] = data >> 8;
      ram[addr.inc.mask16] = data.mask8;
    }

    if (top == 0xc0) {
      vdp.write16(addr.mask16, data);
    }

    if (top == 0xa1) {
      writeIo16(addr, data);
    }

    if (top == 0xa0 && busZ80.busreq) {
      busZ80.write(addr.mask16, data >> 8);
      busZ80.write(addr.inc.mask16, data.mask8);
    }
  }

  int readIo16(int addr) {
    return switch (addr) {
      0x00 => 0x20, // domestic, ntsc, no fdd, version 0
      0x02 => 0x00, // data 1 (ctrl1)
      0x04 => 0x00, // data 2 (ctrl2)
      0x06 => 0x00, // data 3 (exp)
      0x08 => 0x00, // ctrl 1 (ctrl1)
      0x0a => 0x00, // ctrl 2 (ctrl2)
      0x0c => 0x00, // ctrl 3 (exp)
      0x0e => 0x00, // txdata 1
      0x10 => 0x00, // rxdata 1
      0x12 => 0x00, // s-ctrl 1
      0x14 => 0x00, // txdata 2
      0x16 => 0x00, // rxdata 2
      0x18 => 0x00, // s-ctrl 2
      0x1a => 0x00, // txdata 3
      0x1c => 0x00, // rxdata 3
      0x1e => 0x00, // s-ctrl 3
      0x1000 => 0x00, // memory mode
      0x1100 => busZ80.busreq ? 0 : 1, // z80 busreq
      0x1200 => 0x00, // z80 reset
      _ => 0x00,
    };
  }

  void writeIo16(int addr, int data) {
    final _ = switch (addr) {
      0x00 => 0x20, // domestic, ntsc, no fdd, version 0
      0x02 => 0x00, // data 1 (ctrl1)
      0x04 => 0x00, // data 2 (ctrl2)
      0x06 => 0x00, // data 3 (exp)
      0x08 => 0x00, // ctrl 1 (ctrl1)
      0x0a => 0x00, // ctrl 2 (ctrl2)
      0x0c => 0x00, // ctrl 3 (exp)
      0x0e => 0x00, // txdata 1
      0x10 => 0x00, // rxdata 1
      0x12 => 0x00, // s-ctrl 1
      0x14 => 0x00, // txdata 2
      0x16 => 0x00, // rxdata 2
      0x18 => 0x00, // s-ctrl 2
      0x1a => 0x00, // txdata 3
      0x1c => 0x00, // rxdata 3
      0x1e => 0x00, // s-ctrl 3
      0x1000 => 0x00, // memory mode
      0x1100 => busZ80.busreq = data == 0x0100, // z80 busreq
      0x1200 => busZ80.reset = data == 0x0100, // z80 reset
      _ => 0x00,
    };
  }
}
