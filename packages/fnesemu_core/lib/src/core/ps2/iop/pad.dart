import '../../../pad_button.dart';

/// A digital pad on port 1. The button word is active low. Button bits and
/// names follow the PS1 pad so key maps carry over. The bit layout is from
/// memory and unverified.
class Ps2Pad {
  static const _buttons = [
    (PadButton.up, 4),
    (PadButton.down, 6),
    (PadButton.left, 7),
    (PadButton.right, 5),
    (PadButton("Select"), 0),
    (PadButton("^"), 12),
    (PadButton("#"), 15),
    (PadButton("x"), 14),
    (PadButton("o"), 13),
    (PadButton("L1"), 10),
    (PadButton("Start"), 3),
    (PadButton("R1"), 11),
  ];

  int value = 0xffff;

  List<PadButton> get buttons => _buttons.map((b) => b.$1).toList();

  void keyDown(int id, PadButton button) => _set(id, button, false);

  void keyUp(int id, PadButton button) => _set(id, button, true);

  void _set(int id, PadButton button, bool released) {
    if (id != 0) return;
    for (final (candidate, bit) in _buttons) {
      if (candidate != button) continue;
      value = released ? value | (1 << bit) : value & ~(1 << bit);
    }
  }

  /// The reply to a poll: 0xff, the digital pad ID, 0x5a, then the buttons.
  /// Bytes past the end read as 0xff.
  int reply(int index) => switch (index) {
        1 => 0x41,
        2 => 0x5a,
        3 => value & 0xff,
        4 => value >> 8,
        _ => 0xff,
      };
}
