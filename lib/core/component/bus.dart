// Dart imports:

import '../mapper/rom.dart';
import 'apu.dart';
import 'cpu.dart';
import 'pad.dart';
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

  static const prescalerSize = 1024;
  int timerSize = 0;
  int timerPrescaler = 0;
  int timerCounter = 0;

  execTimer(int cycles) {
    timerPrescaler -= cycles;
    if (timerPrescaler < 0) {
      timerPrescaler += prescalerSize;

      if (timerCounter > 0) {
        timerCounter--;
        if (timerCounter == 0) {
          holdTirq();
        }
      }
    }
  }

  int read(int addr) {
    final bank = addr >> 13;
    final offset = addr & 0x1fff;

    if (bank <= 0x3f) {
      return rom.read(addr);
    } else if (0xf8 <= bank && bank <= 0xfb) {
      return ram[offset];
    } else if (bank == 0xff) {
      // VDC
      if (offset <= 0x0400) {
        return switch (offset & 0x03) {
          0 => vdc.readReg(),
          2 => vdc.readLsb(),
          3 => vdc.readMsb(),
          int() => 0
        };
      }

      switch (offset) {
        case 0x0400:
        case 0x0401:
        case 0x0402:
        case 0x0403:
        case 0x0404:
        case 0x0405:
          return 0; // VCE
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
          return 0; // PSG
        case 0x0c00:
        case 0x0c01:
          return 0; // タイマー
        case 0x1000:
          return joypad.read(addr);

        // 割り込みコントローラ
        case 0x1402:
          return (maskIrq1 ? 0x02 : 0) |
              (maskIrq2 ? 0x01 : 0) |
              (maskTIrq ? 0x04 : 0);
        case 0x1403:
          return (_holdIrq1 ? 0 : 0x02) |
              (_holdIrq2 ? 0x01 : 0) |
              (_holdTirq ? 0x04 : 0);
      }
    }

    return 0xff;
  }

  void write(int addr, int data) {
    final bank = addr >> 13;
    final offset = addr & 0x1fff;

    if (0xf8 <= bank && bank <= 0xfb) {
      ram[offset] = data;
    } else if (bank == 0xff) {
      // VDC
      if (offset < 0x0400) {
        switch (offset & 0x03) {
          case 0:
            vdc.writeReg(data);
            break;
          case 2:
            vdc.writeLsb(data);
            break;
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
            break;
          case 0x03:
            vdc.writeColorTableAddressMsb(data);
            break;
          case 0x04:
            vdc.writeColorTableLsb(data);
            break;
          case 0x05:
            vdc.writeColorTableMsb(data);
            break;
          case _:
            return;
        }
        return;
      }

      switch (offset) {
        // PSG
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

        // タイマー
        case 0x0c00:
          timerSize = data & 0x7f;
          return;
        case 0x0c01:
          if (data & 0x01 != 0 && timerCounter == 0) {
            timerCounter = timerSize;
          } else if (data & 0x01 == 0) {
            timerCounter = 0;
          }
          return;

        case 0x1000:
          return;

        // 割り込みコントローラ
        case 0x1402:
          maskIrq2 = data & 0x01 != 0;
          maskIrq1 = data & 0x02 != 0;
          maskTIrq = data & 0x04 != 0;
          return;
        case 0x1403:
          acknoledgeTirq();
          return;
      }
    }
  }

  void writeVdcReg(value) {
    vdc.writeReg(value);
  }

  void writeVdcLsb(value) {
    vdc.writeLsb(value);
  }

  void writeVdcMsb(value) {
    vdc.writeMsb(value);
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
  }

  void holdIrq() => {};
  void releaseIrq() => {};
}
