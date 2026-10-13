// import '../../util/debug.dart';
import 'dart:typed_data';

import '../../util/int.dart';
import 'bus_m68.dart';
import 'sn76489.dart';
import 'ym2612.dart';
import 'z80/z80.dart';

// final _log = DebugLog('md.bus_z80');

class BusZ80 {
  late BusM68 busM68;
  late Z80 cpu;
  late Sn76489 psg;
  late Ym2612 ym2612;

  BusZ80();

  int bank = 0x00; // shound not be 0x140 = 0xa00000
  final ram = Uint8List(0x2000);

  bool get busReq => cpu.busReq;
  set busReq(bool value) {
    // _log.debugc(() => "z80 busreq:$value m68 pc:${busM68.cpu.pc.x6}");
    cpu.busReq = value;
  }

  bool _reset = false;
  set resetReq(bool value) {
    // _log.debugc(() => "z80 reset:$_reset->$value m68 pc:${busM68.cpu.pc.x6}");
    if (value && !_reset) {
      cpu.reset(keepCycles: true); // reset when resetReq becomes up
    }
    _reset = value;
  }

  void onReset() {
    bank = 0x00;
    _reset = false;
    cpu.busReq = false;
    cpu.reset();
  }

  int read(int addr) {
    if (addr < 0x4000) return ram[addr.mask13]; // mirror of 0x0000-0x1fff

    if (addr < 0x6000) return ym2612.read8(0); // ym2612 a0

    if (addr >= 0x8000) {
      final value = busM68.read16(bank | addr.mask15); // m68 bus
      // _log.debugc(() =>
      //     "z80 read 0x8000-0xffff: ${(bank | addr & 0x7fff).x6} -> ${value.x4}");
      return value.shr8;
    }

    if (addr & 0xff00 == 0x7f00) return busM68.read8(0xc00000 | addr.mask5);

    return 0xff;
  }

  write(int addr, int data) {
    // ram: 0x2000-0x3fff is a mirror of 0x0000-0x1fff
    if (addr < 0x4000) {
      ram[addr.mask13] = data;
      return;
    }

    // ym2612: 0x4000-0x5fff
    if (addr < 0x6000) {
      switch (addr.mask2) {
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
      bank = bank.shr1 & 0x7f8000 | data.shl23 & 0x800000;
      // _log.debugc(() => "bank: ${_bank.x6}");
      return;
    }

    // 0x7f00-0x7f1f: vdp & psg
    if (addr & 0xff00 == 0x7f00) {
      busM68.write8(0xc00000 | addr.mask5, data);
      return;
    }

    // 0x8000-0xffff:  banked m68k address space
    if (addr >= 0x8000) {
      busM68.write8(bank | addr.mask15, data);
      return;
    }
  }

  int input(int port) {
    return 0xff;
  }

  void output(int port, int data) {}

  void assertInt() {
    // _log.debug("z80 assertInt");
    cpu.assertInt();
  }

  void deassertInt() {
    // _log.debug("z80 de-assertInt");
    cpu.deassertInt();
  }
}
