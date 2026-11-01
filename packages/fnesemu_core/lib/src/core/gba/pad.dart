import '../../pad_button.dart';
import '../../pad_source.dart';
import '../../util/int.dart';

/// GBA keypad. Produces the KEYINPUT register value where a 0 bit = pressed.
/// The button list is in the unified key order: the X key is B, the C key
/// is A, Q is L, E is R, Enter is Start and Shift is Select.
class Pad {
  static const _btnA = PadButton("A");
  static const _btnB = PadButton("B");
  static const _btnSelect = PadButton("Select");
  static const _btnStart = PadButton("Start");
  static const _btnL = PadButton("L");
  static const _btnR = PadButton("R");

  static const buttonList = [
    PadButton.up,
    PadButton.down,
    PadButton.left,
    PadButton.right,
    PadButton.none, // S
    PadButton.none, // Z
    _btnB, // X
    _btnA, // C
    PadButton.none, // A
    PadButton.none, // D
    PadButton.none, // W
    _btnL, // Q
    _btnR, // E
    PadButton.none, // 1
    PadButton.none, // 2
    PadButton.none, // 3
    PadButton.none, // 4
    PadButton.none, // R
    _btnStart, // Enter
    _btnSelect, // Shift
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
