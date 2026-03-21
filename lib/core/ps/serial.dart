import 'dart:collection';

import 'package:fnesemu/util/int.dart';

import 'bus.dart';
import 'interrupt.dart';

abstract class SioDevice {
  void reset();
  void resetStep();
  SioResponse notify(int txData);
  String dump();
}

class SioResponse {
  final bool ignored;
  final int rxData;
  final bool ack;
  final bool clearRxFIfo;
  final int delayCycles;

  const SioResponse(this.rxData,
      {this.clearRxFIfo = false,
      this.ack = true,
      this.ignored = false,
      this.delayCycles = 600});
}

class RxData {
  int delay;
  int data;
  bool ack;

  RxData(this.data, {this.ack = true, this.delay = 600});
}

class Serial {
  final Bus bus;
  final SioDevice pad;
  final SioDevice memCard;

  Serial(this.bus, this.pad, this.memCard);

  final txFifo = Queue<int>(); // send queue from pad to cpu
  final rxFifo = Queue<RxData>(); // receive queue from cpu to pad

  bool isRxFifoEmpty() {
    return rxFifo.isEmpty || rxFifo.first.delay > 0;
  }

  int ctrl = 0; // control register
  bool get txen => ctrl.bit0; // tx enable (0: disable, 1: enable)
  bool get rxen => ctrl.bit2; // rx enable (0: disable, 1: enable)
  bool get irqEnabled => ctrl.bit12; // dsr interrupt enable
  bool get port1Selected => !ctrl.bit13; // port 1 or 2

  int mode = 0; // mode register

  int get status => (timer << 11)
      .setBit(0, txFifo.isEmpty)
      .setBit(1, !isRxFifoEmpty())
      .setBit(2, txFifo.isEmpty)
      .setBit(7, dsr)
      .setBit(9, irq); // status register (0x7fff: mask)

  bool irq = false;
  bool dsr = false;

  int timer = 0;
  int timerReload = 0;
  int timerFactor = 0;

  void reset() {
    pad.reset();
    memCard.reset();

    irq = false;
    dsr = false; // /ACK (dsr true = asserted = /ack low)

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

    if (rxFifo.isNotEmpty && rxFifo.first.delay > 0) {
      final data = rxFifo.first;
      data.delay -= clocks;
      if (data.delay <= 0) {
        // debugLog("sio0: data received ${dump().replaceAll("\n", " ")}");
        if (data.ack) {
          if (irqEnabled) {
            // debugLog("sio0: irq ${dump().replaceAll("\n", " ")}");
            bus.setIrq(Interrupt.serial);
          }
          irq = true;
        } else {
          irq = false;
        }
      }
    }

    if (txFifo.isEmpty) {
      return;
    }

    final txData = txFifo.removeFirst();

    for (final device in [pad, memCard]) {
      if (!port1Selected) {
        continue;
      }

      final response = device.notify(txData);
      // debugLog("sio0: notify port1 device: ${device.runtimeType} "
      //     "txData:${txData.hex8} rxData:${response.rxData.hex8} "
      //     "ack:${response.ack} ignored:${response.ignored} "
      //     "${dump().replaceAll("\n", " ")}");
      if (response.ignored) {
        continue;
      }

      rxFifo.add(RxData(response.rxData,
          ack: response.ack, delay: response.delayCycles));

      return;
    }

    rxFifo.add(RxData(0xff, ack: false));
  }

  int readData() {
    if (isRxFifoEmpty()) {
      // debugLog("sio0: readData: empty 0 ${dump().replaceAll("\n", " ")}");
      return 0;
    }

    final result = rxFifo.removeFirst();
    // debugLog(
    //     "sio0:  read<--: ${result.data.hex8} ${dump().replaceAll("\n", " ")}");
    return result.data;
  }

  int readMode() => mode;
  int readControl() => ctrl;

  int readBaudrate() => timerReload;

  int readStatus() {
    final result = status;
    dsr = false; // dsr (=/ack) reset
    // debugLog(
    //     "sio0: readStatus: ${result.hex16} ${dump().replaceAll("\n", " ")}");
    return result;
  }

  void writeData(int val) {
    if (txFifo.isNotEmpty) {
      return;
    }
    // debugLog("sio0: write-->: ${val.hex8} ${dump().replaceAll("\n", " ")}");

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
      txFifo.clear();
      rxFifo.clear();
      for (final device in [pad, memCard]) {
        device.resetStep();
      }
    }

    // irq acknowledge
    if (ctrl.bit4) {
      irq = false;
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
      "serial: p:${port1Selected ? "1" : "2"} irq:${irq ? "1" : "0"} ctrl:${ctrl.hex16} status:${status.hex16} timer:${timer.hex24} "
      "tx:${txFifo.map((e) => e.hex8).toList()} rx:${rxFifo.map((e) => e.data.hex8).toList()}\n"
      "pad: ${pad.dump()} "
      "memcard: ${memCard.dump()}";
}
