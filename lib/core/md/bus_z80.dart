import 'dart:typed_data';

import 'bus_m68.dart';
import 'z80/z80.dart';

class BusZ80 {
  late BusM68 busM68;
  late Z80 cpu;

  BusZ80();

  int _bank = 0x00; // shound not be 0x140 = 0xa00000

  bool get busreq => cpu.halted;
  set busreq(bool value) => cpu.halted = value;

  bool _reset = false;
  set reset(bool value) => (!_reset & value) ? onReset() : 0;

  final ram = Uint8List(0x2000);

  void onReset() {
    _bank = 0x00;
    _reset = true;
    cpu.reset();
  }

  int read(int addr) {
    if (addr < 0x2000) return ram[addr];

    if (addr >= 0x8000) return busM68.read(_bank << 15 | addr & 0x7fff);

    return switch (addr) {
      0x4000 => 0x00, // ym2612 a0
      0x4001 => 0x00, // ym2612 d0
      0x4002 => 0x00, // ym2612 a1
      0x4003 => 0x00, // ym2612 d1
      0x6000 => _bank, // bank register
      0x7f11 => 0x00, // psg
      _ => 0x00,
    };
  }

  write(int addr, int data) {
    if (addr < 0x2000) return ram[addr] = data;

    if (addr >= 0x8000) return write(_bank << 15 | _bank & 0x7fff, data);

    switch (addr) {
      case 0x4000: // ym2612 a0
      case 0x4001: // ym2612 d0
      case 0x4002: // ym2612 a1
      case 0x4003: // ym2612 d1
        break;
      case 0x6000: // bank register
        _bank = (_bank << 1 | data & 1) & 0x1ff;
        break;
      case 0x7f11: // psg
        break;
    }
  }

  int input(int port) {
    return 0xff;
  }

  void output(int port, int data) {}
}
