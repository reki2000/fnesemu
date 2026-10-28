import '../../../pad_button.dart';
import '../../../pad_source.dart';

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

  /// where the held buttons are read from, set by the core
  PadSource source = const NoPadSource();

  List<PadButton> get buttons => _buttons.map((b) => b.$1).toList();

  /// the buttons as the 16-bit status word, 0 = pressed
  int get value {
    var value = 0xffff;
    for (final (button, bit) in _buttons) {
      if (source.isPressed(0, button)) value &= ~(1 << bit);
    }
    return value;
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
