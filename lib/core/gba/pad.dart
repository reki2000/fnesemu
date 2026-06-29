import '../pad_button.dart';

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

  // KEYINPUT bit position per button name
  static const _bit = {
    "A": 0,
    "B": 1,
    "Select": 2,
    "Start": 3,
    "right": 4,
    "left": 5,
    "up": 6,
    "down": 7,
    "R": 8,
    "L": 9,
  };

  int _pressed = 0; // 1 bit = currently pressed

  /// KEYINPUT: bits 0..9, 0=pressed. unused high bits read as 0.
  int get keyInput => (~_pressed) & 0x03ff;

  void keyDown(int id, PadButton b) {
    final n = _bit[b.name];
    if (n != null) _pressed |= (1 << n);
  }

  void keyUp(int id, PadButton b) {
    final n = _bit[b.name];
    if (n != null) _pressed &= ~(1 << n);
  }

  List<PadButton> get buttons => buttonList;
}
