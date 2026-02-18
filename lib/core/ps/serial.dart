import 'dart:collection';

import 'package:fnesemu/util/int.dart';

import 'bus.dart';
import 'interrupt.dart';

abstract class SioDevice {
  void reset();
  void resetStep();
  SioResponse notify(int txData, bool port1);
  String dump();
}

class SioResponse {
  final bool ignored;
  final int rxData;
  final bool ack;
  final bool clearRxFIfo;

  const SioResponse(this.rxData,
      {this.clearRxFIfo = false, this.ack = true, this.ignored = false});
}

class Serial {
  final Bus bus;
  final SioDevice pad;
  final SioDevice memCard;

  Serial(this.bus, this.pad, this.memCard);

  final txFifo = Queue<int>(); // send queue from pad to cpu
  final rxFifo = Queue<int>(); // receive queue from cpu to pad

  int ctrl = 0; // control register
  bool get txen => ctrl.bit0; // tx enable (0: disable, 1: enable)
  bool get rxen => ctrl.bit2; // rx enable (0: disable, 1: enable)
  bool get dsrIntEnabled => ctrl.bit12; // dsr interrupt enable
  bool get port1Selected => !ctrl.bit13; // port 1 or 2

  int mode = 0; // mode register

  int get status => (timer << 11)
      .setBit(0, txFifo.isEmpty)
      .setBit(1, rxFifo.isNotEmpty)
      .setBit(2, txFifo.isEmpty)
      .setBit(7, !dsr)
      .setBit(9, irq); // status register (0x7fff: mask)

  bool dsr = false;
  bool irq = false;
  bool irqRequired = false;

  int timer = 0;
  int timerReload = 0;
  int timerFactor = 0;

  void reset() {
    pad.reset();
    memCard.reset();
    irqRequired = false;

    ctrl = 0;
    mode = 0;
    txFifo.clear();
    rxFifo.clear();
  }

  void exec(int clocks) {
    timer -= clocks;
    if (timer <= 0) {
      timer += timerReload * timerFactor;
    }

    if (irqRequired) {
      if (dsrIntEnabled) {
        // debugLog("sio0: irq ${dump().replaceAll("\n", " ")}");
        bus.setIrq(Interrupt.serial);
      }

      irqRequired = false;
      return;
    }

    if (txFifo.isEmpty) {
      return;
    }

    final txData = txFifo.removeFirst();

    if (port1Selected) {
      for (final device in [pad, memCard]) {
        final response = device.notify(txData, dsr);
        // debugLog("sio0: notify port1 device: ${device.runtimeType} "
        //     "txData:${txData.hex8} rxData:${response.rxData.hex8} "
        //     "ack:${response.ack} ignored:${response.ignored} "
        //     "${dump().replaceAll("\n", " ")}");
        if (!response.ignored) {
          rxFifo.add(response.rxData);

          if (response.ack) {
            irqRequired = true;
            irq = true;
          }

          dsr = response.ack;

          break;
        }
      }
    }

    if (rxFifo.isEmpty) {
      rxFifo.add(0xff);
    }
  }

  int readData() {
    if (rxFifo.isEmpty) {
      return 0xff;
    }

    final result = rxFifo.removeFirst();
    // debugLog("sio0: readData: ${result.hex8} ${dump().replaceAll("\n", " ")}");
    return result;
  }

  int readMode() => mode;
  int readControl() => ctrl;

  int readBaudrate() => timerReload;

  int readStatus() {
    final result = status;
    // debugLog(
    //     "sio0: readStatus: ${result.hex16} ${dump().replaceAll("\n", " ")}");
    return result;
  }

  void writeData(int val) {
    // debugLog("sio0: writeData: ${val.hex8} ${dump().replaceAll("\n", " ")}");
    if (txFifo.isNotEmpty) {
      return;
    }

    txFifo.add(val);
  }

  void writeControl(int val) {
    // debugLog(
    //     "sio0: writeControl: ${val.hex16} ${dump().replaceAll("\n", " ")}");

    ctrl = val;

    // reset when cs deasserted
    if (!ctrl.bit1) {
      dsr = false;
      irq = false;
      irqRequired = false;
      txFifo.clear();
      rxFifo.clear();
      for (final device in [pad, memCard]) {
        device.resetStep();
      }
    }

    // irq acknowledge
    if (ctrl.bit4) {
      irq = false;
      irqRequired = false;
      // bus.resetIrq(Interrupt.serial);
    }
  }

  void writeMode(int val) {
    // debugLog("sio0: writeMode: ${val.hex16} ${dump()}");
    mode = val;
    timerFactor = [1, 1, 16, 64][val & 0x03];
  }

  void writeBaudrate(int val) {
    // debugLog("sio0: writeBaudrate: ${val.hex16} ${dump()}");
    timerReload = val & 0xffff;
  }

  String dump() =>
      "serial: p:${port1Selected ? "1" : "2"} dsr:${dsr ? "1" : "0"} ctrl:${ctrl.hex16} status:${status.hex16} timer:${timer.hex24} "
      "tx:${txFifo.map((e) => e.hex8).toList()} rx:${rxFifo.map((e) => e.hex8).toList()}\n"
      "pad: ${pad.dump()} "
      "memcard: ${memCard.dump()}";
}
