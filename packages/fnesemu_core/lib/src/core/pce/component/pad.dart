import '../../../pad_button.dart';
import '../../../pad_source.dart';
import '../../../util/int.dart';

class Pad {
  final buttons = [
    PadButton.up, // 0
    PadButton.down, // 1
    PadButton.left, // 2
    PadButton.right, // 3
    const PadButton("Select"), // 4
    const PadButton("Run"), // 5
    const PadButton("II"), // 6
    const PadButton("I"), // 7
  ];

  static const controllerNum = 5;

  /// where the held buttons are read from, set by the core
  PadSource source = const NoPadSource();

  bool selectLRDU = false; // else RunSelect12
  bool clear = false;
  int counter = 0;

  reset() {
    selectLRDU = false;
    clear = false;
    counter = 0;
  }

  set port(int data) {
    final newSelect = data.bit0;
    final newClear = data.bit1;
    if (newSelect && !clear && newClear) {
      counter = 0;
    } else if (!clear && !newClear && !selectLRDU && newSelect) {
      if (counter < 0xff) {
        counter++;
      }
    }
    selectLRDU = newSelect;
    clear = newClear;
  }

  int buttonValue(int id, int bit) =>
      !source.isPressed(counter, buttons[id]) ? bit : 0;

  int get port => counter >= controllerNum
      ? 0
      : selectLRDU
          ? buttonValue(2, 0x08) |
              buttonValue(1, 0x04) |
              buttonValue(3, 0x02) |
              buttonValue(0, 0x01)
          : buttonValue(5, 0x08) | // Run
              buttonValue(4, 0x04) | // Select
              buttonValue(6, 0x02) | // II
              buttonValue(7, 0x01); // I

  String dump() {
    final joys = buttons.map(
      (j) => "${j.name}:${source.isPressed(0, j) ? "*" : "-"}",
    );
    return "$joys";
  }
}
