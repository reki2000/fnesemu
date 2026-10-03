import 'package:fnesemu/util/int.dart';
// Dart imports:

import 'dart:typed_data';

import '../mapper/rom.dart';
import '../../sram.dart';
import 'cdrom.dart';
import 'cpu.dart';
import 'pad.dart';
import 'pic.dart';
import 'psg.dart';
import 'timer.dart';
import 'vdc.dart';
import 'vpc.dart';

class Bus {
  Bus() {
    cdrom = PceCdrom(this);
  }

  late final Cpu2 cpu;
  late final Vdc vdc;
  late final Vdc vdc2;
  final Vpc vpc = Vpc();
  late final Psg psg;
  late final Timer timer;
  late final Pic pic;
  late final PceCdrom cdrom;
  Sram sram = Sram();
  final superCdRam = Uint8List(192 * 1024);

  // ST0/1/2 are routed to the VDC selected by
  // the VPC ($000E bit0). On a plain PC Engine this is always VDC1.
  Vdc get stVdc => vpc.enabled && vpc.vdcSelect == 1 ? vdc2 : vdc;

  // touching any VDC2 register also latches SuperGrafx mode.
  Vdc get _vdc2Sgx {
    vpc.enabled = true;
    return vdc2;
  }

  Rom rom = Rom(List.filled(4, Uint8List(0x2000)));

  final joypad = Pad();

  // 0: original ram 8kb
  // 1-3: supergfx additional ram banks 24k
  // 4-11: cdrom buffer 64k
  final List<List<int>> ram = List.generate(12, (_) => List.filled(0x2000, 0));

  // on a plain PC Engine, banks f9-fb mirror the 8kb work ram at f8.
  // on SuperGrafx they are independent 8kb banks (32kb total).
  int _workRamIndex(int bank) => vpc.enabled ? bank.mask2 : 0;

  int read(int addr) {
    final bank = addr.shr13;
    final offset = addr & 0x1fff;

    if (cdrom.enabled && bank >= 0x68 && bank <= 0x7f) {
      return superCdRam[(bank - 0x68) * 0x2000 + offset];
    }
    if (bank == 0xf7 && cdrom.enabled) {
      return cdrom.backupEnabled && offset < 0x800 ? sram.read8(offset) : 0xff;
    }
    if (bank <= 0x7f) {
      return rom.read(addr);
    }

    if (0x80 <= bank && bank <= 0x87) {
      return ram[(bank & 0x07) + 4][offset];
    }

    if (0xf8 <= bank && bank <= 0xfb) {
      return ram[_workRamIndex(bank)][offset];
    }

    if (bank == 0xff) {
      // VDC
      if (offset < 0x0400) {
        final r = _vdcPort(offset);
        return switch (r) {
          0x00 => vdc.readReg(),
          0x02 => vdc.readLsb(),
          0x03 => vdc.readMsb(),
          0x08 || 0x09 || 0x0a || 0x0b || 0x0c || 0x0d || 0x0e => vpc.read(r),
          0x10 => _vdc2Sgx.readReg(),
          0x12 => _vdc2Sgx.readLsb(),
          0x13 => _vdc2Sgx.readMsb(),
          int() => 0
        };
      }

      // VCE
      if (offset < 0x0800) {
        return switch (offset & 0x07) {
          0x04 => vdc.readColorTableLsb(),
          0x05 => vdc.readColorTableMsb(),
          int() => 0xff,
        };
      }

      // PSG
      if (offset < 0x0c00) {
        return 0;
      }

      // Timer
      if (offset < 0x1000) {
        return timer.counter & 0x7f;
      }

      if (offset < 0x1400) {
        return joypad.port.mask4 | 0x30 | (cdrom.enabled ? 0 : 0x80);
      }

      // PIC
      if (offset < 0x1800) {
        return switch (offset & 0x03) {
          0x02 => pic.mask,
          0x03 => pic.hold,
          int() => 0,
        };
      }
    }

    if (bank == 0xff && offset >= 0x1800 && cdrom.enabled) {
      return cdrom.read(offset);
    }
    return 0xff;
  }

  void write(int addr, int data) {
    final bank = addr.shr13;
    final offset = addr & 0x1fff;

    data &= 0xff;
    if (cdrom.enabled && bank >= 0x68 && bank <= 0x7f) {
      superCdRam[(bank - 0x68) * 0x2000 + offset] = data;
      return;
    }
    if (bank == 0xf7 && cdrom.enabled) {
      if (cdrom.backupEnabled && offset < 0x800) sram.write8(offset, data);
      return;
    }
    if (bank == 0xff && offset >= 0x1800 && cdrom.enabled) {
      cdrom.write(offset, data);
      return;
    }
    if (0xf8 <= bank && bank <= 0xfb) {
      // final logAddrs = [0x3cd5];
      // for (final addr in logAddrs) {
      //   if (offset == addr & 0x1fff) {
      //     print(
      //         "ram write: ${addr.x4} ${data.x2}\n${cpu.dump(showRegs: true, showIRQVector: true, showStack: true)}");
      //   }
      // }
      ram[_workRamIndex(bank)][offset] = data;
      return;
    }

    if (bank == 0xff) {
      // VDC
      if (offset < 0x0400) {
        switch (_vdcPort(offset)) {
          case 0x00:
            vdc.writeReg(data);
            return;
          case 0x02:
            vdc.writeLsb(data);
            return;
          case 0x03:
            vdc.writeMsb(data);
            return;
          case 0x08:
          case 0x09:
          case 0x0a:
          case 0x0b:
          case 0x0c:
          case 0x0d:
          case 0x0e:
            vpc.write(offset.mask5, data);
            return;
          case 0x10:
            _vdc2Sgx.writeReg(data);
            return;
          case 0x12:
            _vdc2Sgx.writeLsb(data);
            return;
          case 0x13:
            _vdc2Sgx.writeMsb(data);
            return;
        }
        return;
      }

      // VCE
      if (offset < 0x0800) {
        switch (offset & 0x07) {
          case 0x00:
            return;
          case 0x02:
            vdc.writeColorTableAddressLsb(data);
            return;
          case 0x03:
            vdc.writeColorTableAddressMsb(data);
            return;
          case 0x04:
            vdc.writeColorTableLsb(data);
            return;
          case 0x05:
            vdc.writeColorTableMsb(data);
            return;
        }
        return;
      }

      // PSG
      if (offset < 0x0c00) {
        psg.write(offset & 0x0f, data);
        return;
      }

      // Timer
      if (offset < 0x1000) {
        switch (offset & 0x01) {
          case 0x00:
            timer.size = data & 0x7f;
            return;
          case 0x01:
            timer.trigger(data.bit0);
            return;
        }
        return;
      }

      // I/O
      if (offset < 0x1400) {
        joypad.port = data & 0x03;
        return;
      }

      // PIC
      if (offset < 0x1800) {
        switch (offset & 0x03) {
          case 0x02:
            pic.mask = data & 0x07;
            return;
          case 0x03:
            pic.acknoledgeTirq();
            return;
        }
        return;
      }
    }

    if (0x80 <= bank && bank <= 0x87) {
      ram[(bank & 0x07) + 4][offset] = data;
      return;
    }

    if (bank == 0x00) {
      rom.write(addr, data);
      return;
    }
  }

  // Each VDC has four ports mirrored across its eight-byte block.
  int _vdcPort(int offset) {
    final port = offset.mask5;
    return !port.bit3 ? port & ~0x04 : port;
  }

  void updateVdcIrq() {
    if (vdc.irqPending || vdc2.irqPending) {
      pic.holdIrq1();
    } else {
      pic.acknoledgeIrq1();
    }
  }

  void onNmi() => cpu.holdInterrupt(Interrupt.nmi);

  void onReset() {
    vdc.reset();
    vdc2.reset();
    vpc.reset();
    psg.reset();
    cpu.reset();
    timer.reset();
    pic.reset();
    joypad.reset();
    cdrom.reset();
  }

  void holdIrq() => {};
  void releaseIrq() => {};
}
