import 'dart:collection';

import 'package:fnesemu/util/debug.dart';
import 'package:fnesemu/util/int.dart';

import '../pad_button.dart';

class Pad {
  static const controllerNum = 1;

  Pad();

  void keyDown(int id, PadButton d) {
    if (0 <= id && id < controllerNum) {
      buttonValue |= 1 << _buttons.where((b) => b.$1.name == d.name).first.$2;
    }
    // print("keyDown pad:$id buttonValue:${buttonValue.hex32}");
  }

  void keyUp(int id, PadButton d) {
    if (0 <= id && id < controllerNum) {
      buttonValue &=
          ~(1 << _buttons.where((b) => b.$1.name == d.name).first.$2);
    }
    // print("keyUp pad:$id buttonValue:${buttonValue.hex32}");
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
    (PadButton("△"), 12), // 6
    (PadButton("○"), 13), // 7
    (PadButton("×"), 14), // 8
    (PadButton("□"), 15), // 9
    (PadButton("L1"), 10), // 10
    (PadButton("R1"), 11), // 11
  ];

  int buttonValue = 0;

  final txFifo = Queue<int>(); // send queue from pad to cpu
  final rxFifo = Queue<int>(); // receive queue from cpu to pad

  bool irq = false; // interrupt request

  int readData() {
    debugLog(
        "readData: ${txFifo.isNotEmpty ? txFifo.first.hex32 : "empty"} ${rxFifo.isNotEmpty ? rxFifo.first.hex32 : "empty"}");
    if (txFifo.isEmpty) {
      return 0xffff;
    }

    return txFifo.removeFirst();
  }

  int readModeControl() => 0;

  int readBaudrate() => 0;

  int readStatus() => 0x01.setBit(1, txFifo.isNotEmpty).setBit(9, irq);

  void writeData(int val) {
    debugLog("writeData: $val txFifo:${txFifo.length} rxFifo:${rxFifo.length}");
    if (txFifo.isEmpty) {
      if (val == 0x01) {
        txFifo.clear();
        rxFifo.clear();
        txFifo.add(0x5a41); // digital pad
        txFifo.add(buttonValue);
      }
    } else {
      rxFifo.add(val);
    }
  }

  void writeControl(int val) {
    debugLog(
        "writeControl: $val txFifo:${txFifo.length} rxFifo:${rxFifo.length}");
  }

  void writeMode(int val) {
    debugLog("writeMode: $val txFifo:${txFifo.length} rxFifo:${rxFifo.length}");
    if (val.bit4) {
      irq = false;
    }
  }

  void writeBaudrate(int val) {}
}
