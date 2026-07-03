import 'package:fnesemu/util/int.dart';
// Dart imports:

import 'dart:typed_data';

import '../mapper/rom.dart';
import 'cpu.dart';
import 'pad.dart';
import 'pic.dart';
import 'psg.dart';
import 'timer.dart';
import 'vdc.dart';
import 'vpc.dart';

class Bus {
  late final Cpu2 cpu;
  late final Vdc vdc;
  late final Vdc vdc2;
  late final Vpc vpc;
  late final Psg psg;
  late final Timer timer;
  late final Pic pic;

  // ST0/1/2 and CPU access to $0000-$0007 are routed to the VDC selected by
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
  int _workRamIndex(int bank) => vpc.enabled ? bank & 0x03 : 0;

  int read(int addr) {
    final bank = addr.shr13;
    final offset = addr & 0x1fff;

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
        final r = offset & 0x1f;
        return switch (r) {
          0x00 => stVdc.readReg(),
          0x02 => stVdc.readLsb(),
          0x03 => stVdc.readMsb(),
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
          int() => 0xff
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
        return joypad.port & 0x0f | 0x30;
      }

      // PIC
      if (offset < 0x1800) {
        return switch (offset & 0x03) {
          0x02 => pic.mask,
          0x03 => pic.hold,
          int() => 0
        };
      }
    }

    return 0xff;
  }

  void write(int addr, int data) {
    final bank = addr.shr13;
    final offset = addr & 0x1fff;

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
        switch (offset & 0x1f) {
          case 0x00:
            stVdc.writeReg(data);
            return;
          case 0x02:
            stVdc.writeLsb(data);
            return;
          case 0x03:
            stVdc.writeMsb(data);
            return;
          case 0x08:
          case 0x09:
          case 0x0a:
          case 0x0b:
          case 0x0c:
          case 0x0d:
          case 0x0e:
            vpc.write(offset & 0x1f, data);
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

  void onNmi() => cpu.holdInterrupt(Interrupt.nmi);

  void onReset() {
    vdc.reset();
    vdc2.reset();
    vpc.reset();
    psg.reset();
    cpu.reset();
    timer.reset();
    pic.reset();
  }

  void holdIrq() => {};
  void releaseIrq() => {};
}
