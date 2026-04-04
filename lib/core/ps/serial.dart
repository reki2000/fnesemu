import 'dart:collection';

import 'package:fnesemu/util/int.dart';

import '../../util/debug.dart' show debugLog;
import 'bus.dart';
import 'interrupt.dart';

const _debugLog = false;
void _debug(String log) {
  if (_debugLog) {
    debugLog(log);
  }
}

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
  final int delay;

  const SioResponse(this.rxData,
      {this.ack = true, this.ignored = false, this.delay = 600});
}

class Serial {
  final Bus bus;
  final SioDevice pad;
  final SioDevice memCard1;
  // final SioDevice memCard2;

  Serial(
    this.bus,
    this.pad,
    this.memCard1,
    /*this.memCard2*/
  );

  final txFifo = Queue<int>(); // send queue from pad to cpu
  final rxFifo = Queue<int>(); // receive queue from cpu to pad
  int _prev = 0;

  bool isRxFifoEmpty() => rxFifo.isEmpty;

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
  int irqDelay = 0;

  int timer = 0;
  int timerReload = 0;
  int timerFactor = 0;

  void reset() {
    pad.reset();
    memCard1.reset();

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

    if (irqDelay > 0) {
      irqDelay -= clocks;
      if (irqDelay <= 0) {
        irqDelay = 0;
        if (irqEnabled) {
          _debug("sio0: irq delay expired ${dump().replaceAll("\n", " ")}");
          bus.setIrq(Interrupt.serial);
          irq = true;
        }
      }
    }
  }

  int readData() {
    if (isRxFifoEmpty()) {
      _debug("sio0: readEmpt: ${_prev.hex8} ${dump().replaceAll("\n", " ")}");
      return _prev;
    }

    _prev = rxFifo.removeFirst();
    _debug("sio0:  read<--: ${_prev.hex8} ${dump().replaceAll("\n", " ")}");
    return _prev;
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
    _debug("sio0: write-->: ${val.hex8} ${dump().replaceAll("\n", " ")}");

    final txData = val;

    for (final device in port1Selected ? [pad, memCard1] : [/*memCard2*/]) {
      final response = device.notify(txData);

      // if (device.runtimeType != Pad) {
      // debugLog(
      //     "sio0: notify port${port1Selected ? "1" : "2"} ${device.runtimeType} "
      //     "txData:${txData.hex8} rxData:${response.rxData.hex8} "
      //     "ack:${response.ack} ignored:${response.ignored} "
      //     "${dump().replaceAll("\n", " ")}");
      // }
      if (response.ignored) {
        continue;
      }

      rxFifo.add(response.rxData);
      if (response.ack) {
        irqDelay = response.delay;
      }

      return;
    }

    // if (port1Selected) {
    //   debugLog(
    //       "sio0: no device responded to txData:${txData.hex8} ${dump().replaceAll("\n", " ")}");
    // }

    rxFifo.add(0xff);
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
      for (final device in [pad, memCard1 /*, memCard2*/]) {
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
      "sio0: p:${port1Selected ? "1" : "2"} irq:${irq ? "1" : "0"} ctrl:${ctrl.hex16} status:${status.hex16} timer:${timer.hex24} "
      "tx:${txFifo.map((e) => e.hex8).toList()} "
      "rx:${rxFifo.map((e) => e.hex8).toList()}\n"
      "pad: ${pad.dump()} "
      "mcd1: ${memCard1.dump()} ";
  // "mcd2: ${memCard2.dump()}";
}
