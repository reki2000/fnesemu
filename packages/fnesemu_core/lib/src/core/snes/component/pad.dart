import '../../../pad_button.dart';
import '../../../util/int.dart';

/// SNES standard pad. bit layout of the auto-joypad word ($4219$4218):
/// B Y Select Start Up Down Left Right A X L R - - - -  (b15..b0)
class SnesPad {
  static const _b = PadButton("B");
  static const _y = PadButton("Y");
  static const _select = PadButton("Select");
  static const _start = PadButton("Start");
  static const _a = PadButton("A");
  static const _x = PadButton("X");
  static const _l = PadButton("L");
  static const _r = PadButton("R");

  static const buttons = [
    PadButton.up,
    PadButton.down,
    PadButton.left,
    PadButton.right,
    // in the order of the keys A S Z X C Q W E R D
    _y,
    _b,
    _select,
    PadButton.none,
    _start,
    _l,
    _x,
    _r,
    PadButton.none,
    _a,
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
