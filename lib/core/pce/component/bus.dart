// Dart imports:

import '../../../util.dart';
import '../mapper/rom.dart';
import 'cpu.dart';
import 'pad.dart';
import 'pic.dart';
import 'psg.dart';
import 'timer.dart';
import 'vdc.dart';

class Bus {
  late final Cpu2 cpu;
  late final Vdc vdc;
  late final Psg psg;
  late final Timer timer;
  late final Pic pic;

  late Rom rom;

  final joypad = Pad();

  final List<int> ram = List.filled(0x2000, 0);

  int read(int addr) {
    final bank = addr >> 13;
    final offset = addr & 0x1fff;

    if (bank <= 0x7f) {
      return rom.read(addr);
    }

    if (0xf8 <= bank && bank <= 0xfb) {
      return ram[offset];
    }

    if (bank == 0xff) {
      // VDC
      if (offset < 0x0400) {
        return switch (offset & 0x03) {
          0 => vdc.readReg(),
          2 => vdc.readLsb(),
          3 => vdc.readMsb(),
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
        return joypad.port & 0x0f | 0xf0;
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
    final bank = addr >> 13;
    final offset = addr & 0x1fff;

    if (0xf8 <= bank && bank <= 0xfb) {
      // final logAddrs = [0x33cb, 0x3420, 0x1c, 0x1d];
      // for (final addr in logAddrs) {
      //   if (offset == addr & 0x1fff) {
      //     print(
      //         "ram write: ${hex16(addr)} ${hex8(data)}\n${cpu.dump(showRegs: true, showIRQVector: true, showStack: true)}");
      //   }
      // }
      ram[offset] = data;
      return;
    }

    if (bank == 0xff) {
      // VDC
      if (offset < 0x0400) {
        switch (offset & 0x03) {
          case 0:
            vdc.writeReg(data);
            return;
          case 2:
            vdc.writeLsb(data);
            return;
          case 3:
            vdc.writeMsb(data);
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
            timer.trigger(bit0(data));
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
  }

  void onNmi() => cpu.holdInterrupt(Interrupt.nmi);

  void onReset() {
    vdc.reset();
    psg.reset();
    cpu.reset();
    timer.reset();
    pic.reset();
  }

  void holdIrq() => {};
  void releaseIrq() => {};
}
