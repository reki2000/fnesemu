import 'dart:collection';

import 'package:fnesemu/util/int.dart';

import '../pad_button.dart';
import 'bus.dart';
import 'interrupt.dart';

class PadStatus {
  static const int waitAddr = 0; //
  static const int waitCommand = 1; //
  static const int waitPadNo = 2; //
  static const int waitMotor1 = 3; //
  static const int waitMotor2 = 4; //
}

class Pad {
  static const controllerNum = 1;
  final Bus bus;

  Pad(this.bus);

  int buttonValue = 0;

  bool padAckRequired = false;
  int padNo = 0;
  int padReceiveValue = 0;
  int padStep = PadStatus.waitAddr;

  void reset() {
    buttonValue = 0xffff;
    padAckRequired = false;
    padNo = 0;
    padStep = 0;

    ctrl = 0;
    mode = 0;
    _status = 0;
    txFifo.clear();
    rxFifo.clear();
  }

  void keyDown(int id, PadButton d) {
    if (0 <= id && id < controllerNum) {
      buttonValue &=
          ~(1 << _buttons.where((b) => b.$1.name == d.name).first.$2);
    }
    // debugLog("pad: keyDown $id buttonValue:${buttonValue.hex16}");
  }

  void keyUp(int id, PadButton d) {
    if (0 <= id && id < controllerNum) {
      buttonValue |= 1 << _buttons.where((b) => b.$1.name == d.name).first.$2;
    }
    // debugLog("pad: keyUp $id buttonValue:${buttonValue.hex16}");
  }

  List<PadButton> get buttons => _buttons.map((b) => b.$1).toList();

  // (pad button, bit number for status value)
  static const _buttons = [
    (PadButton.up, 4),
    (PadButton.down, 6),
    (PadButton.left, 7),
    (PadButton.right, 5),
    (PadButton("Select"), 0), // 4
    (PadButton("Start"), 3), // 5
    (PadButton("^"), 12), // 6
    (PadButton("o"), 13), // 7
    (PadButton("x"), 14), // 8
    (PadButton("#"), 15), // 9
    (PadButton("L1"), 10), // 10
    (PadButton("R1"), 11), // 11
  ];

  void exec() {
    // debugLog(
    //     "pad: exec ${padAckRequired ? "Ack" : "   "} status:$padStep ${dump()}");

    if (padAckRequired) {
      _status = _status.setBit(7, true); // DSR on (ack)
      if (ctrl.bit12) {
        bus.setIrq(Interrupt.pad);
      }

      padAckRequired = false;
      return;
    }

    _status = _status.setBit(7, false); // DSR off

    if (txFifo.isEmpty) {
      return;
    }

    padReceiveValue = txFifo.removeFirst();

    switch (padStep) {
      case PadStatus.waitAddr:
        if (padReceiveValue == 0x01 && port1) {
          rxFifo.clear();
          rxFifo.add(0xff);
          // debugLog("pad: 0x01 -> -- <- ${dump()}");
          padStep = PadStatus.waitCommand;
          padAckRequired = true;
        }

      case PadStatus.waitCommand:
        rxFifo.add(0x41); // digital pad
        // debugLog("pad: 0x42 -> 0x41 <- $padStep ${dump()}");
        padStep = PadStatus.waitPadNo;
        padAckRequired = true;

      case PadStatus.waitPadNo:
        padNo = padReceiveValue & 0x0f;
        rxFifo.add(0x5a); // digital pad
        // debugLog("pad: ${padNo.hex8} -> 0x5a <- ${dump()}");
        padStep = PadStatus.waitMotor1;
        padAckRequired = true;

      case PadStatus.waitMotor1:
        if (padNo == 0) {
          rxFifo.add(buttonValue.mask8);
        } else {
          rxFifo.add(0); // no pad
        }
        padStep = PadStatus.waitMotor2;
        padAckRequired = true;

      case PadStatus.waitMotor2:
        if (padNo == 0) {
          rxFifo.add(buttonValue >> 8 & 0xff);
        } else {
          rxFifo.add(0); // no pad
        }
        padStep = PadStatus.waitAddr;
    }
  }

  final txFifo = Queue<int>(); // send queue from pad to cpu
  final rxFifo = Queue<int>(); // receive queue from cpu to pad

  int ctrl = 0; // control register
  int mode = 0; // mode register
  int _status = 0; // status register

  int get status => _status
      .setBit(0, txFifo.isEmpty)
      .setBit(1, rxFifo.isNotEmpty)
      .setBit(2, txFifo.isEmpty); // status register (0x7fff: mask)

  bool get cs => ctrl.bit1; // chip select
  bool get txen => ctrl.bit0; // tx enable (0: disable, 1: enable)
  bool get rxen => ctrl.bit2; // rx enable (0: disable, 1: enable)

  bool port1 = false; // port 1 (0: pad, 1: memory card)

  int readData() {
    if (rxFifo.isEmpty) {
      return 0xff;
    }

    final result = rxFifo.removeFirst();
    // debugLog("pad: readData: ${result.hex8} ${dump()}");
    return result;
  }

  int readMode() => mode;
  int readControl() => ctrl;

  int readBaudrate() => 0;

  int readStatus() {
    final result = status;
    // debugLog("pad: readStatus: ${result.hex16} ${dump()}");
    return result;
  }

  void writeData(int val) {
    // debugLog("pad: writeData: ${val.hex8} ${dump()}");
    if (!ctrl.bit0 || !cs || !txen) {
      return;
    }

    if (port1) {
      txFifo.add(val);
    }
  }

  void writeControl(int val) {
    // debugLog("pad: writeControl: ${val.hex16} ${dump()}");

    if (!cs && val.bit1) {
      // chip select
      txFifo.clear();
      rxFifo.clear();
      padAckRequired = false;
      padStep = PadStatus.waitAddr;
      port1 = !val.bit3; // port 1 (0: pad, 1: memory card)
    }

    ctrl = val;

    if (ctrl.bit4) {
      // acknowledge
      _status = _status
          .setBit(2, false)
          .setBit(3, false)
          .setBit(4, false)
          .setBit(9, false);
      bus.ackIrq(Interrupt.pad);
    }

    if (ctrl.bit6) {
      // reset
      txFifo.clear();
      rxFifo.clear();
      padAckRequired = false;
      padStep = PadStatus.waitAddr;
    }
  }

  void writeMode(int val) {
    // debugLog("pad: writeMode: ${val.hex16} ${dump()}");
    mode = val;
  }

  void writeBaudrate(int val) {}

  String dump() =>
      "pad: button:${buttonValue.hex16} ctrl:${ctrl.hex16} status:${status.hex16} "
      "tx:${txFifo.map((e) => e.hex8).toList()} rx:${rxFifo.map((e) => e.hex8).toList()}";
}
