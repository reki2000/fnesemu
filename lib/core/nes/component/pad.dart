// Project imports:
import '../../../util.dart';
import '../../pad_button.dart';

class Joypad {
  late Map<PadButton, bool> isPressed;

  final buttons = [
    PadButton.left,
    PadButton.right,
    PadButton.up,
    PadButton.down,
    const PadButton("Sel"),
    const PadButton("Sta"),
    const PadButton("B"),
    const PadButton("A"),
  ];

  final scanOrder = [
    7, // A
    6, // B
    4, // select
    5, // start
    2, // up
    3, // down
    0, // left
    1, // right
  ];

  var counter = 0;

  Joypad() {
    isPressed = {for (var e in buttons) e: false};
  }

  void keyDown(int controllerId, PadButton d) {
    isPressed[d] = true;
  }

  void keyUp(int controllerID, PadButton d) {
    isPressed[d] = false;
  }

  void _reset1() {
    counter = 0;
  }

  void write(int addr, int data) {
    if (bit0(data)) {
      return;
    }

    switch (addr) {
      case 0x4016:
        _reset1();
        break;
      case 0x04017:
        break;
    }
  }

  int read(int addr) {
    switch (addr) {
      case 0x4016:
        return _read1();
      case 0x4017:
        return _read2();
      default:
        return 0x00;
    }
  }

  int _read1() {
    final result = isPressed[buttons[scanOrder[counter]]]! ? 0x41 : 0x40;

    counter++;
    if (counter == 8) {
      counter = 0;
    }

    return result;
  }

  int _read2() {
    return 0x40;
  }

  String dump() {
    final joys = buttons.map((j) => "${j.name}:${isPressed[j]! ? "*" : "-"}");
    return "$joys";
  }
}
