// import '../../util/debug.dart';
import 'dart:typed_data';

import '../../components/m68k/bus.dart';
import '../../components/m68k/cpu.dart';
import '../../components/sn76489/sn76489.dart';
import '../../util/int.dart';
import '../../util/state.dart';
import 'bus_z80.dart';
import 'cd/md_cdrom.dart';
import 'pad.dart';
import 'rom.dart';
import 'vdp.dart';
import 'ym2612.dart';

// final _log = DebugLog('md.bus_m68');

class BusM68 implements M68Bus {
  BusM68({Uint8List? ram, Pad? pad, Rom? rom})
      : ram = ram ?? Uint8List(0x10000),
        pad = pad ?? Pad(),
        rom = rom ?? Rom();

  late BusZ80 busZ80;
  late M68 cpu;
  late Vdp vdp;
  late Sn76489 psg;
  late Ym2612 fm;

  Rom rom;
  MdCdrom? cdrom;
  int region = 0x00;

  final Pad pad;

  /// Saves logical state while the owning core identifies external media.
  void saveState(StateWriter w) {
    w.section('md-main-bus');
    w.bytes(ram);
    w.int32(region);
    rom.saveState(w);
    pad.saveState(w);
  }

  /// Restores existing buffers and keeps callback and bus wiring.
  void loadState(StateReader s) {
    s.section('md-main-bus');
    s.bytesInto(ram);
    region = s.int32();
    rom.loadState(s);
    pad.loadState(s);
  }

  void onReset() {
    cpu.reset();
    vdp.reset();
    fm.reset();
    psg.reset();
  }

  final Uint8List ram;

  @override
  int read8(int addr) {
    if (cdrom?.mapsMain(addr) ?? false) return cdrom!.readMain8(addr);
    final top = addr.shr16.mask8;

    if (top == 0xff) {
      return ram[addr.mask16];
    }

    if (top < 0x40) {
      final offset = addr & 0x3fffff;

      final romOffset = rom.mapOffset(offset);
      if (romOffset < rom.rom.length) {
        return rom.rom[romOffset];
      }

      if (rom.ramStartAddr <= offset && offset < rom.ramEndAddr) {
        final ramOffset = offset - rom.ramStartAddr;
        return rom.ram[ramOffset.mask16];
      }

      return 0x00;
    }

    if (top == 0xc0) {
      if (addr & 0x1e == 0x10) {
        return psg.read8();
      }

      return (!addr.bit0)
          ? vdp.read16(addr.mask16).shr8
          : vdp.read16(addr & 0xfffe).mask8;
    }

    if (top == 0xa1) {
      // i/o registers (0xa10000-0xa1001f) return the same value on both bytes,
      // other control registers have their status on the even (upper) byte
      final value = readIo16(addr);
      return (addr.bit0 || addr.mask16 < 0x20) ? value.mask8 : value.shr8;
    }

    if (top == 0xa0) {
      return addr < 0xa08000 ? busZ80.read(addr.mask16) : 0x00;
    }

    return 0xff;
  }

  @override
  int read16(int addr) {
    if (cdrom?.mapsMain(addr) ?? false) return cdrom!.readMain16(addr);
    final top = addr.shr16.mask8;

    if (top == 0xff) {
      return ram[addr.mask16].shl8 | ram[addr.inc.mask16];
    }

    if (top < 0x40) {
      final offset = addr & 0x3fffff;

      final romOffset = rom.mapOffset(offset);
      if (romOffset < rom.rom.length - 1) {
        return rom.rom[romOffset].shl8 | rom.rom[romOffset.inc];
      }

      if (rom.ramStartAddr <= offset && offset < rom.ramEndAddr) {
        final ramOffset = offset - rom.ramStartAddr;
        return rom.ram[ramOffset.mask16].shl8 | rom.ram[ramOffset.inc.mask16];
      }

      return 0x00;
    }

    if (top == 0xc0) {
      return vdp.read16(addr.mask16);
    }

    if (top == 0xa1) {
      return readIo16(addr);
    }

    if (top == 0xa0) {
      return addr < 0xa08000
          ? busZ80.read(addr.mask16).shl8 | busZ80.read(addr.inc.mask16)
          : 0x00;
    }

    return 0xff;
  }

  @override
  void write8(int addr, int data) {
    if (cdrom?.mapsMain(addr) ?? false) {
      cdrom!.writeMain8(addr, data);
      return;
    }
    final top = addr & 0xff0000;

    if (top == 0xff0000) {
      // if (addr.mask16 == 0x1a) {
      //   _log.debugc(() => "write8: ${addr.x8} ${data.x2}");
      // }
      ram[addr.mask16] = data;
      return;
    }

    if (top == 0xc00000) {
      if (addr & 0x1e == 0x10) {
        psg.write8(data);
        return;
      }

      // byte writes to the vdp are duplicated to both bytes of the bus
      write16(addr, data.shl8 | data);
      return;
    }

    if (top == 0xa10000) {
      if (addr & 0xfffff0 == 0xa130f0) {
        rom.writeBankRegister(addr, data);
        return;
      }
      addr.bit0 ? writeIo16(addr, data) : writeIo16(addr, data.shl8);
      return;
    }

    if (top == 0xa00000) {
      // _log.debugc(() => "write z80 addr:${addr.mask16.x4}:${data.x2}");
      busZ80.write(addr.mask16, data);
      return;
    }

    if (top < 0x400000) {
      final offset = addr & 0x3fffff;

      if (rom.ramStartAddr <= offset && offset < rom.ramEndAddr) {
        final ramOffset = offset - rom.ramStartAddr;
        rom.ram[ramOffset.mask16] = data;
      }

      return;
    }
  }

  @override
  void write16(int addr, int data) {
    if (cdrom?.mapsMain(addr) ?? false) {
      cdrom!.writeMain8(addr, data.shr8);
      cdrom!.writeMain8(addr + 1, data.mask8);
      return;
    }
    final top = addr & 0xff0000;

    if (top == 0xff0000) {
      ram[addr.mask16] = data.shr8;
      ram[addr.inc.mask16] = data.mask8;
      return;
    }

    if (top == 0xc00000) {
      // _log.debugc(() => "write16: ${addr.x8} ${data.x4} pc:${cpu.pc.x6}");
      vdp.write16(addr.mask16, data);
      return;
    }

    if (top == 0xa10000) {
      if (addr & 0xfffff0 == 0xa130f0) {
        rom.writeBankRegister(addr, data.mask8);
        return;
      }
      writeIo16(addr.mask16, data);
      return;
    }

    if (top == 0xa00000) {
      busZ80.write(addr.mask16, data.shr8);
      busZ80.write(addr.inc.mask16, data.mask8);
      return;
    }

    if (top < 0x400000) {
      final offset = addr & 0x3fffff;

      if (rom.ramStartAddr <= offset && offset < rom.ramEndAddr) {
        final ramOffset = offset - rom.ramStartAddr;
        rom.ram[ramOffset.mask16] = data.shr8;
        rom.ram[ramOffset.inc.mask16] = data;
      }

      return;
    }
  }

  int readIo16(int addr) {
    return switch (addr & 0xfffe) {
      0x00 =>
        region | (cdrom == null ? 0x20 : 0), // region, ntsc, no fdd, version 0
      0x02 ||
      0x04 ||
      0x06 =>
        pad.readData(addr.shr1.mask2.dec, cpu.clocks), // data
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
      0x1100 => busZ80.busReq ? 0 : 0x100, // z80 busreq bit8 0:granted
      0x1200 => 0x00, // z80 reset
      _ => 0x00,
    };
  }

  void writeIo16(int addr, int data) {
    // _log.debugc(() => "io:${addr.x8} ${data.x2}");
    final _ = switch (addr & 0xfffe) {
      0x00 => 0x20, // domestic, ntsc, no fdd, version 0
      0x02 ||
      0x04 ||
      0x06 =>
        pad.writeData(addr.shr1.mask2.dec, data, cpu.clocks), // data 1 (ctrl1)
      0x08 ||
      0x0a ||
      0x0c =>
        pad.writeCtrl(addr.shr1.mask2, data), // ctrl 1 (ctrl1)
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
      0x1100 => busZ80.busReq = data.bit8, // z80 busreq
      0x1200 => busZ80.resetReq = !data.bit8, // z80 reset
      _ => 0x00,
    };
  }

  void interrupt(int level) {
    cpu.interrupt(level);
  }
}
