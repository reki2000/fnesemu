import '../../pad_button.dart';
import '../../pad_source.dart';

/// the two control pads of the sms core
class Pad {
  static const button1 = PadButton("1");
  static const button2 = PadButton("2");
  static const pause = PadButton("Pause");
  static const start = PadButton("Start");

  /// where the held buttons are read from, set by the core
  PadSource source = const NoPadSource();

  /// the buttons in the bit order of the ports
  static const _buttons = [
    PadButton.up,
    PadButton.down,
    PadButton.left,
    PadButton.right,
    button1,
    button2,
  ];

  // active low: up down left right 1 2 of a controller
  int _state(int id) {
    var bits = 0x3f;
    for (var i = 0; i < _buttons.length; i++) {
      if (source.isPressed(id, _buttons[i])) bits &= ~(1 << i);
    }
    return bits;
  }

  bool get startPressed => source.isPressed(0, start);

  /// port 0xdc: the controller 1 and the up/down of the controller 2
  int portA() => _state(0) | (_state(1) & 3) << 6;

  /// port 0xdd: the rest of the controller 2 and the TH lines, which return
  /// the level written to the port 0x3f when they are outputs. the domestic
  /// console returns the inverted level, which software uses as its region
  int portB(int ioControl, {bool domestic = false}) {
    final invert = domestic ? 1 : 0;
    final thA = ioControl & 0x02 == 0 ? ioControl >> 5 & 1 ^ invert : 1;
    final thB = ioControl & 0x08 == 0 ? ioControl >> 7 & 1 ^ invert : 1;
    return _state(1) >> 2 | 0x30 | thA << 6 | thB << 7;
  }
}
