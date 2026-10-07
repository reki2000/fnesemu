import 'package:fnesemu/util/int.dart';

import '../pad_button.dart';

class Pad {
  late List<Map<String, bool>> isPressed;

  static const controllerNum = 3;

  Pad() {
    isPressed = List.generate(
        controllerNum, (_) => {for (var e in _hw) e.name: false});
  }

  void keyDown(int id, PadButton d) {
    if (0 <= id && id < controllerNum && d != PadButton.none) {
      isPressed[id][d.name] = true;
    }
    // print("kwydown pad:$id counter:${counter[id]} isPressed:${isPressed[id]}");
  }

  void keyUp(int id, PadButton d) {
    if (0 <= id && id < controllerNum && d != PadButton.none) {
      isPressed[id][d.name] = false;
    }
    // print("keyup pad:$id counter:${counter[id]} isPressed:${isPressed[id]}");
  }

  static const _mode = PadButton("Mode");
  static const _start = PadButton("Start");
  static const _a = PadButton("A");
  static const _b = PadButton("B");
  static const _c = PadButton("C");
  static const _x = PadButton("X");
  static const _y = PadButton("Y");
  static const _z = PadButton("Z");

  /// the buttons in the order of buttonIndice
  static const _hw = [
    PadButton.up,
    PadButton.down,
    PadButton.left,
    PadButton.right,
    _mode, // 4
    _start, // 5
    _a, // 6
    _b, // 7
    _c, // 8
    _x, // 9
    _y, // 10
    _z, // 11
  ];

  /// the buttons in the order of the keys A S Z X C Q W E R D
  List<PadButton> get buttons => const [
        PadButton.up,
        PadButton.down,
        PadButton.left,
        PadButton.right,
        _x,
        _y,
        _a,
        _b,
        _c,
        _mode,
        PadButton.none,
        _start,
        PadButton.none,
        _z,
      ];

  static const buttonIndice = [
    [8, 7, 3, 2, 1, 0],
    [5, 6, -2, -2, 1, 0],
    [8, 7, 3, 2, 1, 0],
    [5, 6, -2, -2, -2, -2],
    [8, 7, 4, 9, 10, 11],
    [5, 6, -1, -1, -1, -1],
    [8, 7, 3, 2, 1, 0],
    [5, 6, -2, -2, 1, 0],
  ];

  List<int> counter = [0, 0, 0];
  List<bool> th = [false, false, false];

  int buttonValue(int id, int index, int bit) =>
      !isPressed[id][_hw[index].name]! ? bit : 0;

  void writeData(int id, int val) {
    if (th[id] != val.bit6) {
      th[id] = !th[id];
      counter[id]++;
      if (counter[id] == 8) {
        counter[id] = 0;
      }
    }
    // print("pad:$id writeData ${val.x2} th:${th[id]} counter:${counter[id]}");
  }

  int readData(int id) {
    final val = buttonIndice[counter[id]].fold(
        0,
        (prev, idx) =>
            prev.shl1 |
            (idx == -2
                ? 0
                : (idx == -1 || !isPressed[id][_hw[idx].name]!)
                    ? 1
                    : 0));
    // print(
    //     "pad:$id counter:${counter[id]} ${val.x2} isPressed:${isPressed[id]}");
    return val | (th[id] ? 0x40 : 0);
  }

  void writeCtrl(int id, int val) {
    if (val.bit6) {
      th[id] = true;
    }
    counter[id] = 0;
    // print("pad:$id writeCtrl ${val.x2} th:${th[id]} counter:${counter[id]}");
  }
}
