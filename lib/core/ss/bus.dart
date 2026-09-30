import 'dart:typed_data';

import 'package:fnesemu/util/debug.dart';
import 'package:fnesemu/util/int.dart';

import 'cdblock.dart';
import 'cpu.dart';
import 'scsp.dart';
import 'scu.dart';
import 'smpc.dart';
import 'vdp1.dart';
import 'vdp2.dart';

/// SS main bus (SH-2 external area).
///
/// 0000000-00FFFFF: boot ROM (512KB)
/// 0100000-017FFFF: SMPC
/// 0180000-01FFFFF: backup RAM (32KB, odd bytes)
/// 0200000-02FFFFF: work RAM low (1MB)
/// 1000000-17FFFFF: MINIT (slave FRT input capture)
/// 1800000-1FFFFFF: SINIT (master FRT input capture)
/// 2000000-58FFFFF: A-bus (cartridge, CD block)
/// 5A00000-5BFFFFF: SCSP
/// 5C00000-5DFFFFF: VDP1
/// 5E00000-5FBFFFF: VDP2
/// 5FE0000-5FEFFFF: SCU
/// 6000000-7FFFFFF: work RAM high (1MB)
class Bus implements SsCpuBus {
  late final Smpc smpc;
  late final Scu scu;
  late final Vdp1 vdp1;
  late final Vdp2 vdp2;
  late final Scsp scsp;
  late final CdBlock cdblock;

  late SsCpu master;
  late SsCpu slave;

  final bios = Uint8List(512 * 1024);
  late final biosData = ByteData.sublistView(bios);

  final wramL = Uint8List(1024 * 1024);
  late final wramLData = ByteData.sublistView(wramL);

  final wramH = Uint8List(1024 * 1024);
  late final wramHData = ByteData.sublistView(wramH);

  // backup RAM: 32KB, accessed at odd addresses
  int Function(int) bramRead = (_) => 0xff;
  void Function(int, int) bramWrite = (_, __) {};

  static const bramSize = 0x8000;

  static Uint8List get blankBram {
    final ram = Uint8List(bramSize);
    const header = "BackUpRam Format";
    for (int i = 0; i < 0x40; i++) {
      ram[i] = header.codeUnitAt(i % header.length);
    }
    return ram;
  }

  void reset() {
    wramL.fillRange(0, wramL.length, 0);
    wramH.fillRange(0, wramH.length, 0);
  }

  @override
  int read8(int addr) {
    addr &= 0x7ffffff;

    if (addr >= 0x6000000) {
      return wramH[addr & 0xfffff];
    }

    if (addr < 0x100000) {
      return bios[addr & 0x7ffff];
    }

    if (addr < 0x180000) {
      return addr.bit0 ? smpc.read(addr.shr1 & 0x3f) : 0xff;
    }

    if (addr < 0x200000) {
      return addr.bit0 ? bramRead(addr.shr1 & (bramSize - 1)) : 0xff;
    }

    if (addr < 0x300000) {
      return wramL[addr & 0xfffff];
    }

    final d16 = read16(addr & ~1);
    return addr.bit0 ? d16.mask8 : d16.shr8;
  }

  @override
  int read16(int addr) {
    addr &= 0x7fffffe;

    if (addr >= 0x6000000) {
      return wramHData.getUint16(addr & 0xffffe);
    }

    if (addr < 0x100000) {
      return biosData.getUint16(addr & 0x7fffe);
    }

    if (addr < 0x180000) {
      return 0xff00 | smpc.read(addr.shr1 & 0x3f);
    }

    if (addr < 0x200000) {
      return 0xff00 | bramRead(addr.shr1 & (bramSize - 1));
    }

    if (addr < 0x300000) {
      return wramLData.getUint16(addr & 0xffffe);
    }

    if (addr < 0x1000000) {
      return 0xffff; // unmapped
    }

    if (addr < 0x2000000) {
      return 0xffff; // MINIT / SINIT
    }

    if (addr < 0x5800000) {
      // A-bus CS0 / CS1 / dummy: no cartridge
      return 0xffff;
    }

    if (addr < 0x5900000) {
      return cdblock.read16(addr & 0xfffff);
    }

    if (addr < 0x5a00000) {
      return 0xffff;
    }

    if (addr < 0x5b00000) {
      return scsp.readRam16(addr & 0x7ffff);
    }

    if (addr < 0x5c00000) {
      return scsp.readReg16(addr & 0xfff);
    }

    if (addr < 0x5c80000) {
      return vdp1.vramData.getUint16(addr & 0x7fffe);
    }

    if (addr < 0x5d00000) {
      return vdp1.readFb16(addr & 0x3fffe);
    }

    if (addr < 0x5e00000) {
      return vdp1.readReg(addr & 0x1f);
    }

    if (addr < 0x5f00000) {
      return vdp2.vramData.getUint16(addr & 0x7fffe);
    }

    if (addr < 0x5f80000) {
      return vdp2.readCram16(addr & 0xffe);
    }

    if (addr < 0x5fc0000) {
      return vdp2.readReg(addr & 0x1fe);
    }

    if (addr >= 0x5fe0000 && addr < 0x5ff0000) {
      final d32 = scu.read32(addr & 0xfc);
      return addr.bit1 ? d32.mask16 : d32.shr16;
    }

    return 0xffff;
  }

  @override
  int read32(int addr) {
    addr &= 0x7fffffc;

    if (addr >= 0x6000000) {
      return wramHData.getUint32(addr & 0xffffc);
    }

    if (addr < 0x100000) {
      return biosData.getUint32(addr & 0x7fffc);
    }

    if (addr >= 0x200000 && addr < 0x300000) {
      return wramLData.getUint32(addr & 0xffffc);
    }

    if (addr >= 0x5fe0000 && addr < 0x5ff0000) {
      return scu.read32(addr & 0xfc);
    }

    if (addr >= 0x5c00000 && addr < 0x5c80000) {
      return vdp1.vramData.getUint32(addr & 0x7fffc);
    }

    if (addr >= 0x5e00000 && addr < 0x5f00000) {
      return vdp2.vramData.getUint32(addr & 0x7fffc);
    }

    return read16(addr).shl16 | read16(addr + 2);
  }

  @override
  void write8(int addr, int data) {
    addr &= 0x7ffffff;
    data &= 0xff;

    if (addr >= 0x6000000) {
      wramH[addr & 0xfffff] = data;
      return;
    }

    if (addr < 0x100000) {
      return; // rom
    }

    if (addr < 0x180000) {
      if (addr.bit0) smpc.write(addr.shr1 & 0x3f, data);
      return;
    }

    if (addr < 0x200000) {
      if (addr.bit0) bramWrite(addr.shr1 & (bramSize - 1), data);
      return;
    }

    if (addr < 0x300000) {
      wramL[addr & 0xfffff] = data;
      return;
    }

    if (addr >= 0x1000000 && addr < 0x2000000) {
      _writeInit(addr);
      return;
    }

    if (addr >= 0x5a00000 && addr < 0x5b00000) {
      scsp.writeRam8(addr & 0x7ffff, data);
      return;
    }

    if (addr >= 0x5b00000 && addr < 0x5c00000) {
      scsp.writeReg8(addr & 0xfff, data);
      return;
    }

    if (addr >= 0x5c00000 && addr < 0x5c80000) {
      vdp1.vram[addr & 0x7ffff] = data;
      return;
    }

    if (addr >= 0x5c80000 && addr < 0x5d00000) {
      vdp1.writeFb8(addr & 0x3ffff, data);
      return;
    }

    if (addr >= 0x5e00000 && addr < 0x5f00000) {
      vdp2.vram[addr & 0x7ffff] = data;
      return;
    }

    if (addr >= 0x5f00000 && addr < 0x5f80000) {
      vdp2.writeCram8(addr & 0xfff, data);
      return;
    }

    if (addr >= 0x5fe0000 && addr < 0x5ff0000) {
      final shift = (3 - (addr & 3)) * 8;
      scu.write32(addr & 0xfc, data << shift, 0xff << shift);
      return;
    }

    // other 8-bit writes to 16-bit devices are merged into 16-bit writes
    final d16 = addr.bit0 ? data : data.shl8;
    _write16Device(addr & ~1, d16, addr.bit0 ? 0x00ff : 0xff00);
  }

  @override
  void write16(int addr, int data) {
    addr &= 0x7fffffe;
    data &= 0xffff;

    if (addr >= 0x6000000) {
      wramHData.setUint16(addr & 0xffffe, data);
      return;
    }

    if (addr < 0x100000) {
      return;
    }

    if (addr < 0x180000) {
      smpc.write(addr.shr1 & 0x3f, data.mask8);
      return;
    }

    if (addr < 0x200000) {
      bramWrite(addr.shr1 & (bramSize - 1), data.mask8);
      return;
    }

    if (addr < 0x300000) {
      wramLData.setUint16(addr & 0xffffe, data);
      return;
    }

    if (addr >= 0x1000000 && addr < 0x2000000) {
      _writeInit(addr);
      return;
    }

    if (addr >= 0x5fe0000 && addr < 0x5ff0000) {
      final shift = addr.bit1 ? 0 : 16;
      scu.write32(addr & 0xfc, data << shift, 0xffff << shift);
      return;
    }

    _write16Device(addr, data, 0xffff);
  }

  void _write16Device(int addr, int data, int mask) {
    if (addr < 0x5800000) {
      return; // A-bus: no cartridge
    }

    if (addr < 0x5900000) {
      cdblock.write16(addr & 0xfffff, data);
      return;
    }

    if (addr < 0x5a00000) {
      return;
    }

    if (addr < 0x5b00000) {
      scsp.writeRam16(addr & 0x7fffe, data, mask);
      return;
    }

    if (addr < 0x5c00000) {
      scsp.writeReg16(addr & 0xffe, data, mask);
      return;
    }

    if (addr < 0x5c80000) {
      final a = addr & 0x7fffe;
      final old = vdp1.vramData.getUint16(a);
      vdp1.vramData.setUint16(a, old & ~mask | data & mask);
      return;
    }

    if (addr < 0x5d00000) {
      vdp1.writeFb16(addr & 0x3fffe, data, mask);
      return;
    }

    if (addr < 0x5e00000) {
      if (mask == 0xffff) vdp1.writeReg(addr & 0x1f, data);
      return;
    }

    if (addr < 0x5f00000) {
      final a = addr & 0x7fffe;
      final old = vdp2.vramData.getUint16(a);
      vdp2.vramData.setUint16(a, old & ~mask | data & mask);
      return;
    }

    if (addr < 0x5f80000) {
      final a = addr & 0xffe;
      final old = vdp2.readCram16(a);
      vdp2.writeCram16(a, old & ~mask | data & mask);
      return;
    }

    if (addr < 0x5fc0000) {
      final a = addr & 0x1fe;
      final old = vdp2.readReg(a);
      vdp2.writeReg(a, old & ~mask | data & mask);
      return;
    }
  }

  @override
  void write32(int addr, int data) {
    addr &= 0x7fffffc;
    data &= 0xffffffff;

    if (addr >= 0x6000000) {
      wramHData.setUint32(addr & 0xffffc, data);
      return;
    }

    if (addr >= 0x200000 && addr < 0x300000) {
      wramLData.setUint32(addr & 0xffffc, data);
      return;
    }

    if (addr >= 0x5fe0000 && addr < 0x5ff0000) {
      scu.write32(addr & 0xfc, data, 0xffffffff);
      return;
    }

    if (addr >= 0x5c00000 && addr < 0x5c80000) {
      vdp1.vramData.setUint32(addr & 0x7fffc, data);
      return;
    }

    if (addr >= 0x5e00000 && addr < 0x5f00000) {
      vdp2.vramData.setUint32(addr & 0x7fffc, data);
      return;
    }

    write16(addr, data.shr16);
    write16(addr + 2, data.mask16);
  }

  void _writeInit(int addr) {
    if (addr < 0x1800000) {
      slave.frtInputCapture(); // MINIT
    } else {
      master.frtInputCapture(); // SINIT
    }
  }

  void unimpl(String s) => debugLog("ss bus: $s");
}
