import 'package:fnesemu/util/int.dart';

import '../pad_button.dart';
import 'serial.dart' show SioResponse, SioDevice;

class Pad extends SioDevice {
  static const int waitIgnore = -1;
  static const int waitAddr = 0; //
  static const int waitCommand = 1; //
  static const int waitPadNo = 2; //
  static const int waitMotor1 = 3; //
  static const int waitMotor2 = 4; //

  static const controllerNum = 1;

  int buttonValue = 0xffff;

  // (pad button, bit number for status value)
  static const _buttons = [
    (PadButton.up, 4),
    (PadButton.down, 6),
    (PadButton.left, 7),
    (PadButton.right, 5),
    (PadButton("Select"), 0), // 4
    (PadButton("^"), 12), // 6
    (PadButton("#"), 15), // 9
    (PadButton("x"), 14), // 8
    (PadButton("o"), 13), // 7
    (PadButton("L1"), 10), // 10
    (PadButton("Start"), 3), // 5
    (PadButton("R1"), 11), // 11
  ];

  int padStep = waitAddr;

  void keyDown(int id, PadButton d) {
    if (0 <= id && id < controllerNum) {
      final buttonBit = _buttons.where((b) => b.$1 == d).first.$2;
      buttonValue = buttonValue.setBit(buttonBit, false);
    }
    // debugLog("pad: keyDown $id buttonValue:${buttonValue.hex16}");
  }

  void keyUp(int id, PadButton d) {
    if (0 <= id && id < controllerNum) {
      final buttonBit = _buttons.where((b) => b.$1 == d).first.$2;
      buttonValue = buttonValue.setBit(buttonBit, true);
    }
    // debugLog("pad: keyUp $id buttonValue:${buttonValue.hex16}");
  }

  List<PadButton> get buttons => _buttons.map((b) => b.$1).toList();

  @override
  void reset() {
    buttonValue = 0xffff;
    padStep = waitAddr;
  }

  @override
  void resetStep() {
    padStep = waitAddr;
  }

  SioResponse ack(int data, {int delay = 500}) {
    return SioResponse(data, ack: padStep != waitAddr, delay: delay);
  }

  @override
  SioResponse notify(int txData) {
    // if (padStep == waitMotor2) {
    //   debugLog("pad: notify txData:${txData.hex8} dump:${dump()}");
    // }

    switch (padStep) {
      case waitAddr:
        if (txData == 0x01) {
          // debugLog("pad: 0x01 -> -- <- ${dump()}");
          padStep = waitCommand;
          return ack(0xff);
        }

      case waitCommand:
        // debugLog("pad: 0x42 -> 0x41 <- $padStep ${dump()}");
        padStep = waitPadNo;
        return ack(0x41);

      case waitPadNo:
        // debugLog("pad: ${padNo.hex8} -> 0x5a <- ${dump()}");
        padStep = waitMotor1;
        return ack(0x5a);

      case waitMotor1:
        padStep = waitMotor2;
        // debugLog("pad: ${padNo.hex8} -> 0x00 <- ${dump()}");
        return ack(buttonValue.mask8);

      case waitMotor2:
        padStep = waitAddr;
        // debugLog("pad: ${padNo.hex8} -> 0x00 <- ${dump()}");
        return ack(buttonValue.shr8.mask8);
    }

    padStep = waitIgnore;
    return SioResponse(0xff, ignored: true, ack: false);
  }

  @override
  String dump() => "step:$padStep button:${buttonValue.hex16}";
}
