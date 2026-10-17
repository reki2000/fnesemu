import 'dart:typed_data';

import '../../components/sn76489/sn76489.dart';
import '../../components/z80/bus.dart';
import '../../components/z80/z80.dart';
import '../../sram.dart';
import '../../util/int.dart';
import 'pad.dart';
import 'vdp.dart';

enum SmsModel { sg1000, sms, gg }

enum Mapper { none, sega, codemasters }

/// memory map and I/O ports of the SG-1000, Master System and Game Gear
class Bus implements Z80Bus {
  final SmsModel model;
  late final Z80 cpu = Z80(this);
  final Vdp vdp;
  final Sn76489 psg;
  final pad = Pad();

  Bus(this.model)
      : vdp = Vdp(tms: model == SmsModel.sg1000, gg: model == SmsModel.gg),
        psg = Sn76489(ti: model == SmsModel.sg1000);

  Uint8List rom = Uint8List(0x4000);
  Mapper mapper = Mapper.none;

  // the system RAM: 8KB on the Master System and Game Gear, 1KB (mirrored) on
  // the SG-1000. cartridges of the SG-1000 may have 8KB of RAM at 0x2000
  final ram = Uint8List(0x2000);
  int get _ramMask => model == SmsModel.sg1000 ? 0x3ff : 0x1fff;

  // the 32KB battery backed cartridge RAM switched by the Sega mapper
  static const cartRamSize = 0x8000;
  Sram _cartRam = Sram()..init("", Uint8List(cartRamSize));

  // the Sega mapper: 0xfffc control, 0xfffd-0xffff slot 0-2 banks
  final banks = [0, 1, 2];
  int ramControl = 0;

  // the CPU cycles at the start of the current line
  int lineStartCycles = 0;

  // I/O port control (0x3f)
  int ioControl = 0xff;

  // Game Gear: the start button and the stereo setting
  bool ggStart = false;

  void setRom(Uint8List body) {
    // drop a 512 byte copier header
    if (body.length % 0x4000 == 0x200) {
      body = Uint8List.sublistView(body, 0x200);
    }
    rom = body;
    mapper = _detectMapper(body);
  }

  Mapper _detectMapper(Uint8List body) {
    if (model == SmsModel.sg1000 && body.length <= 0xc000) return Mapper.none;
    if (body.length <= 0x8000 && model != SmsModel.sg1000) return Mapper.sega;
    if (body.length >= 0x8000) {
      // codemasters header: a checksum and its complement at 0x7fe6
      final sum = body[0x7fe6] | body[0x7fe7].shl8;
      final inv = body[0x7fe8] | body[0x7fe9].shl8;
      if (sum + inv == 0x10000 && sum != 0) return Mapper.codemasters;
    }
    return Mapper.sega;
  }

  int get _bankCount => (rom.length + 0x3fff) >> 14;

  void reset() {
    ram.fillRange(0, ram.length, 0);
    banks.setAll(0, [0, 1, 2]);
    ramControl = 0;
    ioControl = 0xff;
    lineStartCycles = 0;
    vdp.reset();
    psg.reset();
    cpu.reset();
    // the BIOS leaves the stack pointer at the top of the RAM
    if (model != SmsModel.sg1000) cpu.r.sp = 0xdff0;
  }

  /// attaches the persistent storage of the cartridge RAM
  void attachCartRam(Sram? sram, String id) {
    _cartRam = (sram ?? Sram())..init(id, Uint8List(cartRamSize));
  }

  int _romByte(int bank, int offset) {
    final count = _bankCount;
    final b = bank < count ? bank : bank % count;
    final addr = b.shl14 | offset;
    return addr < rom.length ? rom[addr] : 0xff;
  }

  @override
  int read(int addr) {
    if (addr >= 0xc000) return ram[addr & _ramMask];

    switch (mapper) {
      case Mapper.none:
        if (addr < rom.length) return rom[addr];
        if (model == SmsModel.sg1000 && addr >= 0x2000 && addr < 0x4000) {
          return ram[addr & 0x1fff];
        }
        return 0xff;
      case Mapper.sega:
        if (addr < 0x400) return rom.length > addr ? rom[addr] : 0xff;
        final slot = addr.shr14;
        if (slot == 2 && ramControl.bit3) {
          return _cartRam.read8((ramControl.bit2 ? 0x4000 : 0) | addr.mask14);
        }
        return _romByte(banks[slot], addr.mask14);
      case Mapper.codemasters:
        return _romByte(banks[addr.shr14], addr.mask14);
    }
  }

  @override
  void write(int addr, int data) {
    if (addr >= 0xc000) {
      ram[addr & _ramMask] = data;
      if (mapper == Mapper.sega && addr >= 0xfffc) {
        switch (addr) {
          case 0xfffc:
            ramControl = data;
          case 0xfffd:
            banks[0] = data;
          case 0xfffe:
            banks[1] = data;
          case 0xffff:
            banks[2] = data;
        }
      }
      return;
    }

    switch (mapper) {
      case Mapper.none:
        if (model == SmsModel.sg1000 &&
            addr >= 0x2000 &&
            addr < 0x4000 &&
            rom.length <= 0x2000) {
          ram[addr & 0x1fff] = data;
        }
      case Mapper.sega:
        if (addr >= 0x8000 && ramControl.bit3) {
          _cartRam.write8((ramControl.bit2 ? 0x4000 : 0) | addr.mask14, data);
        }
      case Mapper.codemasters:
        if (addr.mask14 == 0) banks[addr.shr14] = data;
    }
  }

  @override
  int input(int port) {
    port = port.mask8;
    if (model == SmsModel.gg && port < 7) {
      return switch (port) {
        0 => (ggStart ? 0 : 0x80) | 0x40, // overseas, NTSC
        1 => 0x7f,
        2 => 0xff,
        4 => 0xff,
        _ => 0,
      };
    }

    switch (port & 0xc1) {
      case 0x40:
        return vdp.vCounter;
      case 0x41:
        return vdp.hLatch;
      case 0x80:
        return vdp.readData();
      case 0x81:
        return vdp.readStatus();
      case 0xc0:
        return pad.portA();
      case 0xc1:
        return pad.portB(ioControl);
    }
    return 0xff;
  }

  @override
  void output(int port, int data) {
    port = port.mask8;
    if (model == SmsModel.gg && port < 7) {
      if (port == 6) psg.stereo = data;
      return;
    }

    switch (port & 0xc1) {
      case 0x01:
        // a rising edge of a TH pin latches the horizontal counter. the pins
        // set as inputs are pulled up
        int th(int v) => (v | v >> 4) & 0x0a;
        if (th(data) & ~th(ioControl) != 0) {
          vdp.hLatch = Vdp.hCounter(cpu.cycles - lineStartCycles);
        }
        ioControl = data;
      case 0x40:
      case 0x41:
        psg.write8(data);
      case 0x80:
        vdp.writeData(data);
      case 0x81:
        vdp.writeControl(data);
    }
  }

  String dump() =>
      "mapper:${mapper.name} banks:${banks.map((b) => b.x2).join(" ")} "
      "ramctl:${ramControl.x2} io:${ioControl.x2}";
}
