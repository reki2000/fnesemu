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

    // debugLog(
    //     "interrupt: setIrq: ${irqNo.hex8} (${_names[irqNo]}) istat:${status.hex16}(${_statToName(status)}) imask:${mask.hex16}(${_statToName(mask)}) triggered:${mask & status.setBit(irqNo, true) != 0}");
    status = status.setBit(irqNo, true);

    if (mask & status != 0) {
      cpu.setInterruptPending(true);
    }
  }

  void resetIrq(int irqNo) {
    ackIrq(~(1 << irqNo));
  }

  void ackIrq(int ackValue) {
    // if (ackValue.mask16 != 0xffff) {
    //   debugLog(
    //       'interrupt: ack:${ackValue.hex16} (${_statToName(~ackValue)})  istat:${status.hex16}(${_statToName(status)}) imask:${mask.hex16}(${_statToName(mask)})  sr:${cpu.sr.hex32} cause:${cpu.cause.hex32}');
    // }

    status &= ackValue;

    if (mask & status == 0) {
      cpu.setInterruptPending(false);
    }
  }

  static const _names = [
    "vBlank",
    "gpu",
    "cdrom",
    "dma",
    "timer0",
    "timer1",
    "timer2",
    "serial",
    "sio",
    "spu"
  ];

  String _statToName(int stat) {
    return _names
        .asMap()
        .entries
        .where((e) => stat.bit(e.key))
        .map((e) => e.value)
        .join(" ");
  }

  String dump() {
    return "istat:${status.hex16}(${_statToName(status)}) imask:${mask.hex16}(${_statToName(mask)})";
  }
}
