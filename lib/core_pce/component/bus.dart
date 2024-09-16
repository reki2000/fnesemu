// Dart imports:

import '../../util.dart';
import '../mapper/rom.dart';
import 'apu.dart';
import 'cpu.dart';
import 'pad.dart';
import 'timer.dart';
import 'vdc.dart';

class Bus {
  late final Cpu cpu;
  late final Vdc vdc;
  late final Apu apu;

  late Rom rom;

  final joypad = Joypad();

  final List<int> ram = List.filled(0x2000, 0);

  bool _holdIrq1 = false;
  bool _holdIrq2 = false;
  bool _holdTirq = false;

  bool maskIrq1 = false;
  bool maskIrq2 = false;
  bool maskTIrq = false;

  late final Timer timer;

  int read(int addr) {
    final bank = addr >> 13;
    final offset = addr & 0x1fff;

    if (bank <= 0x3f) {
      return rom.read(addr);
    }

    if (0xf8 <= bank && bank <= 0xfb) {
      return ram[offset];
    }

    if (bank == 0xff) {
      // VDC
      if (offset <= 0x0400) {
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
          0x02 => vdc.readColorTableLsb(),
          0x03 => vdc.readColorTableMsb(),
          int() => 0xff
        };
      }

      // PSG
      if (offset < 0x0c00) {
        return 0;
      }

      if (offset < 0x1000) {
        return switch (offset & 0x03) {
          0x00 => timer.counter,
          0x01 => timer.counter,
          int() => 0
        };
      }

      if (offset < 0x1400) {
        return 0;
      }

      if (offset < 0x1800) {
        return switch (offset & 0x03) {
          0x02 => (maskIrq1 ? 0x02 : 0) |
              (maskIrq2 ? 0x01 : 0) |
              (maskTIrq ? 0x04 : 0),
          0x03 => (_holdIrq1 ? 0 : 0x02) |
              (_holdIrq2 ? 0x01 : 0) |
              (_holdTirq ? 0x04 : 0),
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
        switch (offset) {
          case 0x0800:
          case 0x0801:
          case 0x0802:
          case 0x0803:
          case 0x0804:
          case 0x0805:
          case 0x0806:
          case 0x0807:
          case 0x0808:
          case 0x0809:
            return;
        }
        return;
      }

      if (offset < 0x1000) {
        switch (offset & 0x03) {
          // タイマー
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
        return;
      }

      // 割り込みコントローラ
      if (offset < 0x1800) {
        switch (offset & 0x03) {
          case 0x02:
            maskIrq2 = bit0(data);
            maskIrq1 = bit1(data);
            maskTIrq = bit2(data);
            return;
          case 0x03:
            acknoledgeTirq();
            return;
        }
        return;
      }
    }
  }

  holdIrq1() {
    _holdIrq1 = true;
    if (!maskIrq1) {
      cpu.holdInterrupt(Interrupt.irq1);
    }
  }

  holdIrq2() {
    _holdIrq2 = true;
    if (!maskIrq2) {
      cpu.holdInterrupt(Interrupt.irq2);
    }
  }

  holdTirq() {
    _holdTirq = true;
    if (!maskTIrq) {
      cpu.holdInterrupt(Interrupt.tirq);
    }
  }

  acknoledgeIrq1() {
    _holdIrq1 = false;
    cpu.releaseInterrupt(Interrupt.irq1);
  }

  acknoledgeIrq2() {
    _holdIrq2 = false;
    cpu.releaseInterrupt(Interrupt.irq2);
  }

  acknoledgeTirq() {
    _holdTirq = false;
    cpu.releaseInterrupt(Interrupt.tirq);
  }

  void onNmi() => cpu.onNmi();

  void onReset() {
    _holdIrq1 = false;
    _holdIrq2 = false;
    _holdTirq = false;
    maskIrq1 = false;
    maskIrq2 = false;
    maskTIrq = false;

    vdc.reset();
    apu.reset();
    cpu.reset();
    timer.reset();
  }

  void holdIrq() => {};
  void releaseIrq() => {};
}
