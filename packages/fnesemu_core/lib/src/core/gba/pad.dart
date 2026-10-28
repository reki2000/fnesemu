import '../../pad_button.dart';
import '../../pad_source.dart';
import '../../util/int.dart';

/// GBA keypad. Produces the KEYINPUT register value where a 0 bit = pressed.
/// Button order is chosen so the existing key_handler maps keys A/S/Z/X/C/Q
/// (buttons[4..9]) onto Select/Start/A/B/L/R naturally.
class Pad {
  static const _btnA = PadButton("A");
  static const _btnB = PadButton("B");
  static const _btnSelect = PadButton("Select");
  static const _btnStart = PadButton("Start");
  static const _btnL = PadButton("L");
  static const _btnR = PadButton("R");

  static const buttonList = [
    PadButton.up, // 0
    PadButton.down, // 1
    PadButton.left, // 2
    PadButton.right, // 3
    _btnSelect, // 4  (keyA)
    _btnStart, // 5  (keyS)
    _btnA, // 6  (keyZ)
    _btnB, // 7  (keyX)
    _btnL, // 8  (keyC)
    _btnR, // 9  (keyQ)
  ];

  // KEYINPUT bit position per button
  static const _bits = [
    (_btnA, 0),
    (_btnB, 1),
    (_btnSelect, 2),
    (_btnStart, 3),
    (PadButton.right, 4),
    (PadButton.left, 5),
    (PadButton.up, 6),
    (PadButton.down, 7),
    (_btnR, 8),
    (_btnL, 9),
  ];

  /// where the held buttons are read from, set by the core
  PadSource source = const NoPadSource();

  /// KEYINPUT: bits 0..9, 0=pressed. unused high bits read as 0.
  int get keyInput {
    var pressed = 0;
    for (final (button, bit) in _bits) {
      if (source.isPressed(0, button)) pressed |= 1 << bit;
    }
    return (~pressed).mask10;
  }

  List<PadButton> get buttons => buttonList;
}
