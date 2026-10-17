import '../../pad_button.dart';

/// the two control pads of the sms core
class Pad {
  static const button1 = PadButton("1");
  static const button2 = PadButton("2");
  static const pause = PadButton("Pause");
  static const start = PadButton("Start");

  // active low: up down left right 1 2 of each controller
  final _state = [0x3f, 0x3f];

  void reset() => _state.setAll(0, [0x3f, 0x3f]);

  static int _bit(PadButton k) => switch (k.name) {
        "up" => 0x01,
        "down" => 0x02,
        "left" => 0x04,
        "right" => 0x08,
        "1" => 0x10,
        "2" => 0x20,
        _ => 0,
      };

  void keyDown(int id, PadButton k) {
    if (id < 2) _state[id] &= ~_bit(k);
  }

  void keyUp(int id, PadButton k) {
    if (id < 2) _state[id] |= _bit(k);
  }

  /// port 0xdc: the controller 1 and the up/down of the controller 2
  int portA() => _state[0] | (_state[1] & 3) << 6;

  /// port 0xdd: the rest of the controller 2 and the TH lines, which return
  /// the level written to the port 0x3f when they are outputs. the domestic
  /// console returns the inverted level, which software uses as its region
  int portB(int ioControl, {bool domestic = false}) {
    final invert = domestic ? 1 : 0;
    final thA = ioControl & 0x02 == 0 ? ioControl >> 5 & 1 ^ invert : 1;
    final thB = ioControl & 0x08 == 0 ? ioControl >> 7 & 1 ^ invert : 1;
    return _state[1] >> 2 | 0x30 | thA << 6 | thB << 7;
  }
}
