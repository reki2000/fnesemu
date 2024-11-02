import 'package:fnesemu/util/int.dart';

import '../pad_button.dart';

class Pad {
  late List<Map<String, bool>> isPressed;

  static const controllerNum = 3;

  Pad() {
    isPressed =
        List.filled(controllerNum, {for (var e in buttons) e.name: false});
  }

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

  List<PadButton> get buttons => [
        PadButton.up,
        PadButton.down,
        PadButton.left,
        PadButton.right,
        const PadButton("Mod"), // 4
        const PadButton("Start"), // 5
        const PadButton("A"), // 6
        const PadButton("B"), // 7
        const PadButton("C"), // 8
        const PadButton("X"), // 9
        const PadButton("Y"), // 10
        const PadButton("Z"), // 11
      ];

  static const buttonBits = [
    [8, 7, 3, 2, 1, 0],
    [6, 5, -2, -2, 1, 0],
    [8, 7, 3, 2, 1, 0],
    [6, 5, -2, -2, -2, -2],
    [8, 7, 4, 9, 10, 11],
    [6, 6, -1, -1, -1, -1],
    [8, 7, 3, 2, 1, 0],
    [6, 5, -2, -2, 1, 0],
  ];

  List<int> counter = [0, 0, 0];
  List<bool> th = [false, false, false];

  int buttonValue(int id, int index, int bit) =>
      !isPressed[id][buttons[index].name]! ? bit : 0;

  void writeData(int id, int val) {
    if (th[id] != val.bit6) {
      th[id] = !th[id];
      counter[id]++;
      if (counter[id] == 8) {
        counter[id] = 0;
      }
    }
  }

  int readData(int id) {
    final val =
        buttonBits[counter[id]].reduce((prev, idx) => prev << 1 | idx == -2
            ? 0
            : idx == -1 || isPressed[id][buttons[idx].name]!
                ? 1
                : 0);
    print("pad:$id counter:${counter[id]} ${val.hex8}");
    return val;
  }

  void writeCtrl(int id, int val) {
    if (val.bit6) {
      th[id] = true;
      counter[id] = 0;
    }
  }
}
