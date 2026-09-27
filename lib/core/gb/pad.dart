import '../pad_button.dart';
import 'bus.dart';

/// joypad register P1 (FF00)
class Pad {
  final Bus _bus;

  static const select = PadButton("Sel");
  static const start = PadButton("Sta");
  static const b = PadButton("B");
  static const a = PadButton("A");

  final buttons = const [
    PadButton.up,
    PadButton.down,
    PadButton.left,
    PadButton.right,
    select,
    start,
    b,
    a,
  ];

  // active low bits: right left up down / a b select start
  int _directions = 0x0f;
  int _actions = 0x0f;
  int _select = 0x30;

  Pad(this._bus);

  void reset() {
    _directions = 0x0f;
    _actions = 0x0f;
    _select = 0x30;
  }

  static int _dirBit(PadButton k) => switch (k.name) {
        "right" => 0x01,
        "left" => 0x02,
        "up" => 0x04,
        "down" => 0x08,
        _ => 0,
      };

  static int _actBit(PadButton k) => switch (k.name) {
        "A" => 0x01,
        "B" => 0x02,
        "Sel" => 0x04,
        "Sta" => 0x08,
        _ => 0,
      };

  void keyDown(int controllerId, PadButton k) {
    if (controllerId != 0) {
      return;
    }
    final before = _directions << 4 | _actions;
    _directions &= ~_dirBit(k);
    _actions &= ~_actBit(k);
    if (before != (_directions << 4 | _actions)) {
      _bus.requestInterrupt(Bus.intJoypad);
    }
  }

  void keyUp(int controllerId, PadButton k) {
    if (controllerId != 0) {
      return;
    }
    _directions |= _dirBit(k);
    _actions |= _actBit(k);
  }

  int read() {
    var v = 0x0f;
    if (_select & 0x10 == 0) {
      v &= _directions;
    }
    if (_select & 0x20 == 0) {
      v &= _actions;
    }
    return 0xc0 | _select | v;
  }

  void write(int data) => _select = data & 0x30;
}
