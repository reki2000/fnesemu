import 'package:fnesemu/core/pce/component/bus.dart';

import '../../../util/util.dart';
import 'cpu.dart';

class Pic {
  late final Bus bus;

  Pic(this.bus) {
    bus.pic = this;
  }

  bool _holdIrq1 = false;
  bool _holdIrq2 = false;
  bool _holdTirq = false;

  bool maskIrq1 = false;
  bool maskIrq2 = false;
  bool maskTIrq = false;

  reset() {
    _holdIrq1 = false;
    _holdIrq2 = false;
    _holdTirq = false;
    maskIrq1 = false;
    maskIrq2 = false;
    maskTIrq = false;
  }

  set mask(int data) {
    maskIrq2 = bit0(data);
    maskIrq1 = bit1(data);
    maskTIrq = bit2(data);
  }

  int get mask =>
      (maskIrq1 ? 0x02 : 0) | (maskIrq2 ? 0x01 : 0) | (maskTIrq ? 0x04 : 0);

  int get hold =>
      (_holdIrq1 ? 0 : 0x02) | (_holdIrq2 ? 0x01 : 0) | (_holdTirq ? 0x04 : 0);

  holdIrq1() {
    _holdIrq1 = true;
    if (!maskIrq1) {
      bus.cpu.holdInterrupt(Interrupt.irq1);
    }
  }

  holdIrq2() {
    _holdIrq2 = true;
    if (!maskIrq2) {
      bus.cpu.holdInterrupt(Interrupt.irq2);
    }
  }

  holdTirq() {
    _holdTirq = true;
    if (!maskTIrq) {
      bus.cpu.holdInterrupt(Interrupt.tirq);
    }
  }

  acknoledgeIrq1() {
    _holdIrq1 = false;
    bus.cpu.releaseInterrupt(Interrupt.irq1);
  }

  acknoledgeIrq2() {
    _holdIrq2 = false;
    bus.cpu.releaseInterrupt(Interrupt.irq2);
  }

  acknoledgeTirq() {
    _holdTirq = false;
    bus.cpu.releaseInterrupt(Interrupt.tirq);
  }
}
