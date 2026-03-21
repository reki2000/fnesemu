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
    (PadButton("Start"), 3), // 5
    (PadButton("^"), 12), // 6
    (PadButton("o"), 13), // 7
    (PadButton("x"), 14), // 8
    (PadButton("#"), 15), // 9
    (PadButton("L1"), 10), // 10
    (PadButton("R1"), 11), // 11
  ];

  int padNo = 0;
  int padStep = waitAddr;

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

  @override
  void reset() {
    buttonValue = 0xffff;
    padNo = 0;
    padStep = waitAddr;
  }

  @override
  void resetStep() {
    padStep = waitAddr;
  }

  @override
  SioResponse notify(int txData) {
    if (padStep != waitAddr) {
      // debugLog("pad: notify txData:${txData.hex8} dump:${dump()}");
    }

    switch (padStep) {
      case waitAddr:
        if (txData == 0x01) {
          // debugLog("pad: 0x01 -> -- <- ${dump()}");
          padStep = waitCommand;
          return SioResponse(0xff);
        }

      case waitCommand:
        // debugLog("pad: 0x42 -> 0x41 <- $padStep ${dump()}");
        padStep = waitPadNo;
        return SioResponse(0x41);

      case waitPadNo:
        padNo = txData & 0x0f;
        // debugLog("pad: ${padNo.hex8} -> 0x5a <- ${dump()}");
        padStep = waitMotor1;
        return SioResponse(0x5a);

      case waitMotor1:
        padStep = waitMotor2;
        return SioResponse(padNo == 0 ? buttonValue.mask8 : 0);

      case waitMotor2:
        padStep = waitAddr;
        return SioResponse(padNo == 0 ? buttonValue >> 8 & 0xff : 0,
            ack: false);
    }

    padStep = waitIgnore;
    return SioResponse(0xff, ignored: true, ack: false);
  }

  @override
  String dump() => "padNo:$padNo step:$padStep button:${buttonValue.hex16}";
}
