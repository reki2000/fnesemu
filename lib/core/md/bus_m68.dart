import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';

import 'bus_z80.dart';
import 'm68/m68.dart';
import 'pad.dart';
import 'rom.dart';
import 'vdp.dart';

class BusM68 {
  BusM68();

  late BusZ80 busZ80;
  late M68 cpu;
  late Vdp vdp;

  Rom rom = Rom();

  final pad = Pad();

  void onReset() {}

  final ram = Uint8List(0x10000);

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
      // m68 ram area
      return ram[addr.mask16];
    }

    if (top == 0xa0) {
      // z80 area
      return addr < 0xa08000 ? busZ80.read(addr.mask16) : 0x00;
    }

    if (top == 0xa1) {
      // system i/o area
      return switch (addr.mask16) {
        0x01 => 0x20, // domestic, ntsc, no fdd, version 0
        0x03 => 0x00, // data 1 (ctrl1)
        0x05 => 0x00, // data 2 (ctrl2)
        0x07 => 0x00, // data 3 (exp)
        0x09 => 0x00, // ctrl 1 (ctrl1)
        0x0b => 0x00, // ctrl 2 (ctrl2)
        0x0d => 0x00, // ctrl 3 (exp)
        0x0f => 0x00, // txdata 1
        0x11 => 0x00, // rxdata 1
        0x13 => 0x00, // s-ctrl 1
        0x15 => 0x00, // txdata 2
        0x17 => 0x00, // rxdata 2
        0x19 => 0x00, // s-ctrl 2
        0x1b => 0x00, // txdata 3
        0x1d => 0x00, // rxdata 3
        0x1f => 0x00, // s-ctrl 3
        0x1001 => 0x00, // memory mode
        0x1100 => busZ80.busreq ? 0 : 1, // z80 busreq
        0x1201 => 0x00, // z80 reset
        _ => 0x00,
      };
    }

    if (top == 0xc0) {
      // vdp area
      final offset = addr.mask16;
      return switch (offset) {
        0x00 || 0x02 => vdp.dataH, // data
        0x01 || 0x03 => vdp.dataL, // data
        0x02 || 0x04 => vdp.ctrlH, // ctrl
        0x03 || 0x04 => vdp.ctrlL, // ctrl
        0x08 => vdp.hCounter, // hv counter
        0x09 => vdp.vCounter, // hv counter
        0x10 => 0x00, // psg
        0x11 => 0x00, // psg
        _ => 0x00,
      };
    }

    return 0xff;
  }

  write(int addr, int data) {
    final top = addr >> 16 & 0xff;

    if (top == 0xff) {
      ram[addr.mask16] = data;
    }

    if (top == 0xa0) {
      // z80 area
      busZ80.write(addr.mask16, data);
    }

    if (top == 0xa1) {
      // system i/o area
      return switch (addr.mask16) {
        0x01 => 0x20, // domestic, ntsc, no fdd, version 0
        0x03 => 0x00, // data 1 (ctrl1)
        0x05 => 0x00, // data 2 (ctrl2)
        0x07 => 0x00, // data 3 (exp)
        0x09 => 0x00, // ctrl 1 (ctrl1)
        0x0b => 0x00, // ctrl 2 (ctrl2)
        0x0d => 0x00, // ctrl 3 (exp)
        0x0f => 0x00, // txdata 1
        0x11 => 0x00, // rxdata 1
        0x13 => 0x00, // s-ctrl 1
        0x15 => 0x00, // txdata 2
        0x17 => 0x00, // rxdata 2
        0x19 => 0x00, // s-ctrl 2
        0x1b => 0x00, // txdata 3
        0x1d => 0x00, // rxdata 3
        0x1f => 0x00, // s-ctrl 3
        0x1001 => 0x00, // memory mode
        0x1100 => busZ80.busreq = data == 0x01, // z80 busreq
        0x1200 => busZ80.reset = data == 0x01, // z80 reset
        _ => 0x00,
      };
    }

    if (top == 0xc0) {
      // vdp area
      final offset = addr.mask16;
      return switch (offset) {
        0x00 || 0x02 => vdp.dataH = data, // data
        0x01 || 0x03 => vdp.dataL = data, // data
        0x04 || 0x06 => vdp.ctrlH = data, // ctrl
        0x05 || 0x07 => vdp.ctrlL = data, // ctrl
        0x08 => 0x00, // hv counter
        0x09 => 0x00, // hv counter
        0x10 => 0x00, // psg
        0x11 => 0x00, // psg
        _ => 0x00,
      };
    }
  }

  int input(int port) {
    return 0xff;
  }

  void output(int port, int data) {}
}
