import 'package:fnesemu/util/int.dart';

import '../../pad_button.dart';

/// SNES standard pad. bit layout of the auto-joypad word ($4219$4218):
/// B Y Select Start Up Down Left Right A X L R - - - -  (b15..b0)
class SnesPad {
  static const _b = PadButton("B");
  static const _y = PadButton("Y");
  static const _select = PadButton("Sel");
  static const _start = PadButton("Sta");
  static const _a = PadButton("A");
  static const _x = PadButton("X");
  static const _l = PadButton("L");
  static const _r = PadButton("R");

  static const buttons = [
    PadButton.up,
    PadButton.down,
    PadButton.left,
    PadButton.right,
    _a,
    _b,
    _x,
    _y,
    _l,
    _r,
    _start,
    _select,
  ];

  static const _bit = {
    _b: 15,
    _y: 14,
    _select: 13,
    _start: 12,
    PadButton.up: 11,
    PadButton.down: 10,
    PadButton.left: 9,
    PadButton.right: 8,
    _a: 7,
    _x: 6,
    _l: 5,
    _r: 4,
  };

  int state1 = 0;

  void keyDown(int id, PadButton k) {
    final b = _bit[k];
    if (b != null && id == 0) state1 = state1.setBit(b, true);
  }

  void keyUp(int id, PadButton k) {
    final b = _bit[k];
    if (b != null && id == 0) state1 = state1.setBit(b, false);
  }
}
