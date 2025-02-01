import 'dart:typed_data';

import 'm68/m68_debug.dart';
import 'ym2612.dart';
import '../../util/int.dart';

import 'bus_z80.dart';
import 'm68/m68.dart';
import 'pad.dart';
import 'sn76489.dart';
import 'rom.dart';
import 'vdp.dart';

class BusM68 {
  BusM68();

  late BusZ80 busZ80;
  late M68 cpu;
  late Vdp vdp;
  late Sn76489 psg;
  late Ym2612 fm;

  Rom rom = Rom();

  final pad = Pad();

  void onReset() {
    cpu.reset();
    vdp.reset();
    fm.reset();
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

      if (rom.ramStartAddr <= offset && offset < rom.ramEndAddr) {
        final ramOffset = offset - rom.ramStartAddr;
        return rom.ram[ramOffset.mask16];
      }

      return 0x00;
    }

    if (top == 0xff) {
      return ram[addr.mask16];
    }

    if (top == 0xc0) {
      if (addr & 0x1e == 0x10) {
        return psg.read8();
      }

      return (addr & 0x01 == 0)
          ? vdp.read16(addr.mask16) >> 8
          : vdp.read16(addr & 0xfffe).mask8;
    }

    if (top == 0xa1) {
      return readIo16(addr).mask8;
    }

    if (top == 0xa0) {
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

      if (rom.ramStartAddr <= offset && offset < rom.ramEndAddr) {
        final ramOffset = offset - rom.ramStartAddr;
        return rom.ram[ramOffset.mask16] << 8 | rom.ram[ramOffset.inc.mask16];
      }

      return 0x00;
    }

    if (top == 0xff) {
      return ram[addr.mask16] << 8 | ram[addr.inc.mask16];
    }

    if (top == 0xc0) {
      return vdp.read16(addr.mask16);
    }

    if (top == 0xa1) {
      return readIo16(addr);
    }

    if (top == 0xa0) {
      return addr < 0xa08000
          ? busZ80.read(addr.mask16) << 8 | busZ80.read(addr.inc.mask16)
          : 0x00;
    }

    return 0xff;
  }

  write8(int addr, int data) {
    final top = addr & 0xff0000;

    if (top == 0xff0000) {
      // if (addr.mask16 == 0x1a) {
      //   print("write8: ${addr.hex32} ${data.hex8}");
      // }
      ram[addr.mask16] = data;
      return;
    }

    if (top == 0xc00000) {
      if (addr & 0x1e == 0x10) {
        psg.write8(data);
      }
      return;
    }

    if (top == 0xa10000) {
      addr.bit0 ? writeIo16(addr, data) : writeIo16(addr, data << 8);
      return;
    }

    if (top == 0xa00000) {
      // print("write z80 addr:${addr.mask16.hex16}:${data.hex8}");
      busZ80.write(addr.mask16, data);
      return;
    }

    if (top < 0x40) {
      final offset = addr & 0x3fffff;

      if (rom.ramStartAddr <= offset && offset < rom.ramEndAddr) {
        final ramOffset = offset - rom.ramStartAddr;
        rom.ram[ramOffset.mask16] = data;
      }

      return 0x00;
    }
  }

  write16(int addr, int data) {
    final top = addr & 0xff0000;

    if (top == 0xff0000) {
      if (addr.mask16 == 0xdcfe && data == 0x80) {
        print("cpu: ${cpu.debug()}");
      }
      ram[addr.mask16] = data >> 8;
      ram[addr.inc.mask16] = data.mask8;
      return;
    }

    if (top == 0xc00000) {
      // print("write16: ${addr.hex32} ${data.hex16} pc:${cpu.pc.hex24}");
      vdp.write16(addr.mask16, data);
      return;
    }

    if (top == 0xa10000) {
      writeIo16(addr.mask16, data);
      return;
    }

    if (top == 0xa00000) {
      busZ80.write(addr.mask16, data >> 8);
      busZ80.write(addr.inc.mask16, data.mask8);
      return;
    }

    if (top < 0x40) {
      final offset = addr & 0x3fffff;

      if (rom.ramStartAddr <= offset && offset < rom.ramEndAddr) {
        final ramOffset = offset - rom.ramStartAddr;
        rom.ram[ramOffset.mask16] = data >> 8;
        rom.ram[ramOffset.inc.mask16] = data;
      }

      return 0x00;
    }
  }

  int readIo16(int addr) {
    return switch (addr & 0xfffe) {
      0x00 => 0x20, // domestic, ntsc, no fdd, version 0
      0x02 || 0x04 || 0x06 => pad.readData((addr >> 1 & 0x03).dec), // data
      0x08 || 0x0a || 0x0c => 0x00, // ctrl 1 (ctrl1)
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
      0x1100 => 0, // busZ80.busReq ? 1 : 0, // z80 busreq
      0x1200 => 0x00, // z80 reset
      _ => 0x00,
    };
  }

  void writeIo16(int addr, int data) {
    // print("io:${addr.hex32} ${data.hex8}");
    final _ = switch (addr & 0xfffe) {
      0x00 => 0x20, // domestic, ntsc, no fdd, version 0
      0x02 ||
      0x04 ||
      0x06 =>
        pad.writeData((addr >> 1 & 0x03).dec, data), // data 1 (ctrl1)
      0x08 ||
      0x0a ||
      0x0c =>
        pad.writeCtrl((addr >> 1 & 0x03), data), // ctrl 1 (ctrl1)
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
      0x1100 => busZ80.busReq = data == 0x0100, // z80 busreq
      0x1200 => busZ80.resetReq = data != 0x0100, // z80 reset
      _ => 0x00,
    };
  }

  void interrupt(int level) {
    if (cpu.assertedIntLevel < level) {
      cpu.assertedIntLevel = level;
    }
  }
}
