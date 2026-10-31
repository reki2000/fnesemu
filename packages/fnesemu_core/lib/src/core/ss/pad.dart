import '../../pad_button.dart';
import '../../pad_source.dart';

/// SS standard digital pad
///
/// data byte 0: right, left, down, up, start, A, C, B (active low)
/// data byte 1: R, X, Y, Z, L, 1, 1, 1 (active low)
class Pad {
  static const controllerNum = 2;

  /// The order is the key slots of the keyboard and the touch keys
  /// (`VirtualPadWidget`): the slot of R stays empty.
  static const _buttons = [
    (PadButton.up, 0, 0x10),
    (PadButton.down, 0, 0x20),
    (PadButton.left, 0, 0x40),
    (PadButton.right, 0, 0x80),
    (PadButton("X"), 1, 0x40),
    (PadButton("Y"), 1, 0x20),
    (PadButton("A"), 0, 0x04),
    (PadButton("B"), 0, 0x01),
    (PadButton("C"), 0, 0x02),
    (PadButton("L"), 1, 0x08),
    (PadButton("Start"), 0, 0x08),
    (PadButton("R"), 1, 0x80),
    (PadButton.none, 0, 0), // no bit: the key slot is empty
    (PadButton("Z"), 1, 0x10),
  ];

  /// where the held buttons are read from, set by the core
  PadSource source = const NoPadSource();

  List<PadButton> get buttons => _buttons.map((b) => b.$1).toList();

  /// the two data bytes of the controller [id], active low
  (int, int) data(int id) {
    var d0 = 0xff, d1 = 0xff;
    if (id >= 0 && id < controllerNum) {
      for (final (button, byte, bit) in _buttons) {
        if (bit == 0 || !source.isPressed(id, button)) continue;
        if (byte == 0) {
          d0 &= ~bit;
        } else {
          d1 &= ~bit;
        }
      }
    }
    return (d0, d1 | 0x07);
  }
}
