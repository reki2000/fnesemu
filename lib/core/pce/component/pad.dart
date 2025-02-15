// Project imports:
import '../../../util/util.dart';
import '../../pad_button.dart';

class Pad {
  final buttons = [
    PadButton.up, // 0
    PadButton.down, // 1
    PadButton.left, // 2
    PadButton.right, // 3
    const PadButton("Sel"), // 4
    const PadButton("Run"), // 5
    const PadButton("II"), // 6
    const PadButton("I"), // 7
  ];

  static const controllerNum = 5;

  Pad() {
    isPressed =
        List.filled(controllerNum, {for (var e in buttons) e.name: false});
  }

  late List<Map<String, bool>> isPressed;

  bool selectLRDU = false; // else RunSelect12
  bool clear = false;
  int counter = 0;

  void keyDown(int controllerId, PadButton d) {
    if (0 <= controllerId && controllerId < controllerNum) {
      isPressed[controllerId][d.name] = true;
    }
  }

  void keyUp(int controllerId, PadButton d) {
    if (0 <= controllerId && controllerId < controllerNum) {
      isPressed[controllerId][d.name] = false;
    }
  }

  reset() {
    selectLRDU = false;
  }

  set port(int data) {
    selectLRDU = bit0(data);

    if (selectLRDU) {
      if (!clear) {
        if (bit1(data)) {
          counter = 0;
          clear = true;
        } else {
          counter++;
          clear = false;
        }
      }
    }
  }

  int buttonValue(int id, int bit) =>
      !isPressed[counter][buttons[id].name]! ? bit : 0;

  int get port => selectLRDU
      ? buttonValue(2, 0x08) |
          buttonValue(1, 0x04) |
          buttonValue(3, 0x02) |
          buttonValue(0, 0x01)
      : buttonValue(5, 0x08) | // Run
          buttonValue(4, 0x04) | // Select
          buttonValue(7, 0x02) | // I
          buttonValue(6, 0x01); // II

  String dump() {
    final joys =
        buttons.map((j) => "${j.name}:${isPressed[0][j.name]! ? "*" : "-"}");
    return "$joys";
  }
}
