import 'dart:typed_data';

import 'package:fnesemu/core/md/ym2612.dart';

import 'bus_m68.dart';
import 'psg.dart';
import 'z80/z80.dart';

class BusZ80 {
  late BusM68 busM68;
  late Z80 cpu;
  late Psg psg;
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
    // print("z80 reset:$value m68 pc:${busM68.cpu.pc.hex24}");
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
    if (addr < 0x2000) return ram[addr];

    if (addr >= 0x8000) return busM68.read16(_bank << 15 | addr & 0x7fff) >> 8;

    return switch (addr) {
      0x4000 || 0x4001 || 0x4002 || 0x4003 => ym2612.read8(0), // ym2612 a0
      0x6000 => _bank, // bank register
      0x7f11 => psg.read8(), // psg
      _ => 0xff,
    };
  }

  write(int addr, int data) {
    if (addr < 0x2000) {
      ram[addr] = data;
      return;
    }

    if (addr >= 0x8000) {
      busM68.write8(_bank << 15 | _bank & 0x7fff, data);
      return;
    }

    switch (addr) {
      case 0x4000: // ym2612 a0
        ym2612.writePort8(0, data);
        break;
      case 0x4001: // ym2612 d0
        ym2612.writeData8(0, data);
        break;
      case 0x4002: // ym2612 a1
        ym2612.writePort8(1, data);
        break;
      case 0x4003: // ym2612 d1
        ym2612.writeData8(1, data);
        break;
      case 0x6000: // bank register
        _bank = (_bank << 1 | data & 1) & 0x1ff;
        break;
      case 0x7f11: // psg
        psg.write8(data);
        break;
    }
  }

  int input(int port) {
    return 0xff;
  }

  void output(int port, int data) {}
}
