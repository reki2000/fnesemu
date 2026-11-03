import '../../../util/int.dart';
import '../../../util/state.dart';
import 'bus.dart';
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
    _syncInterrupts();
  }

  /// Saves the pending interrupt lines and the mask register.
  void saveState(StateWriter w) {
    w.section('pce-pic');
    w.boolean(_holdIrq1);
    w.boolean(_holdIrq2);
    w.boolean(_holdTirq);
    w.boolean(maskIrq1);
    w.boolean(maskIrq2);
    w.boolean(maskTIrq);
  }

  /// Restores the state written by [saveState]; the CPU interrupt holds saved in the CPU state take precedence, so no resync is done here.
  void loadState(StateReader s) {
    s.section('pce-pic');
    _holdIrq1 = s.boolean();
    _holdIrq2 = s.boolean();
    _holdTirq = s.boolean();
    maskIrq1 = s.boolean();
    maskIrq2 = s.boolean();
    maskTIrq = s.boolean();
  }

  set mask(int data) {
    maskIrq2 = data.bit0;
    maskIrq1 = data.bit1;
    maskTIrq = data.bit2;
    _syncInterrupts();
    bus.cpu.inhibitIrqOnce();
  }

  void _syncInterrupts() {
    void sync(Interrupt interrupt, bool pending, bool masked) {
      if (pending && !masked) {
        bus.cpu.holdInterrupt(interrupt);
      } else {
        bus.cpu.releaseInterrupt(interrupt);
      }
    }

    sync(Interrupt.irq1, _holdIrq1, maskIrq1);
    sync(Interrupt.irq2, _holdIrq2, maskIrq2);
    sync(Interrupt.tirq, _holdTirq, maskTIrq);
  }

  int get mask =>
      (maskIrq1 ? 0x02 : 0) | (maskIrq2 ? 0x01 : 0) | (maskTIrq ? 0x04 : 0);

  int get hold =>
      (_holdIrq1 ? 0x02 : 0) | (_holdIrq2 ? 0x01 : 0) | (_holdTirq ? 0x04 : 0);

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
