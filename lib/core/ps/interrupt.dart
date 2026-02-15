import 'package:fnesemu/core/ps/r3000/r3000.dart';
import 'package:fnesemu/util/int.dart';

class Interrupt {
  static const vBlank = 0;
  static const gpu = 1;
  static const cdrom = 2;
  static const dma = 3;
  static const timer0 = 4;
  static const timer1 = 5;
  static const timer2 = 6;
  static const serial = 7;
  static const sio = 8;
  static const spu = 9;
}

class InterruptController {
  late final R3000 cpu;

  int status = 0;
  int mask = 0;

  void reset() {
    status = 0;
    mask = 0;
  }

  void setIrq(int irqNo) {
    if (status.bit(irqNo)) {
      return;
    }

    status = status.setBit(irqNo, true);
    // debugLog(
    //     "bus: setIrq: ${irqNo.hex8} istat:${status.hex32} imask:${mask.hex32} triggered:${mask & status != 0}");

    if (mask & status != 0) {
      // debugLog(
      //     "bus: setIrq: ${irqNo.hex8} istat:${status.hex32} imask:${mask.hex32}");
      cpu.setInterruptPending(true);
    }
  }

  void resetIrq(int irqNo) {
    ackIrq(~(1 << irqNo));
  }

  void ackIrq(int ackValue) {
    // if (ackValue.mask16 != 0xffff) {
    //   debugLog(
    //       'interrupt ack:${ackValue.hex16}(${(~ackValue).hex16})  sr:${cpu.sr.hex32} pc:${cpu.instPc.hex32} istat:${status.hex32} mstat:${mask.hex32}');
    // }

    status &= ackValue;

    if (mask & status == 0) {
      cpu.setInterruptPending(false);
    }
  }
}
