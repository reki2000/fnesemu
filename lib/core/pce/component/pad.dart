// Project imports:
import '../../../util.dart';
import '../../pad_button.dart';

class Pad {
  final buttons = [
    PadButton.up, // 0
    PadButton.down, // 1
    PadButton.left, // 2
    PadButton.right, // 3
    PadButton("Sel"), // 4
    PadButton("Run"), // 5
    PadButton("II"), // 6
    PadButton("I"), // 7
  ];

  Pad() {
    isPressed = {for (var e in buttons) e: false};
  }

  late Map<PadButton, bool> isPressed;

  bool selectLRDU = false; // else RunSelect12
  bool clear = false;

  void keyDown(int controllerId, PadButton d) {
    isPressed[d] = true;
  }

  void keyUp(int controllerID, PadButton d) {
    isPressed[d] = false;
  }

  reset() {
    selectLRDU = false;
  }

  set port(int data) {
    selectLRDU = bit0(data);
    clear = bit1(data);
  }

  int get port => selectLRDU
      ? (!isPressed[buttons[2]]! ? 0x08 : 0) |
          (!isPressed[buttons[1]]! ? 0x04 : 0) |
          (!isPressed[buttons[3]]! ? 0x02 : 0) |
          (!isPressed[buttons[0]]! ? 0x01 : 0)
      : (!isPressed[buttons[5]]! ? 0x08 : 0) | // Run
          (!isPressed[buttons[4]]! ? 0x04 : 0) | // Select
          (!isPressed[buttons[7]]! ? 0x02 : 0) | // I
          (!isPressed[buttons[6]]! ? 0x01 : 0); // II

  String dump() {
    final joys = buttons.map((j) => "${j.name}:${isPressed[j]! ? "*" : "-"}");
    return "$joys";
  }
}
