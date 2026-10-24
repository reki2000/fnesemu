import '../../pad_button.dart';
import '../../state.dart';

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

  final _state = List.generate(controllerNum, (_) => [0xff, 0xff]);

  List<PadButton> get buttons => _buttons.map((b) => b.$1).toList();

  void keyDown(int id, PadButton k) => _set(id, k, false);
  void keyUp(int id, PadButton k) => _set(id, k, true);

  void _set(int id, PadButton k, bool released) {
    if (id < 0 || id >= controllerNum) {
      return;
    }
    for (final (button, byte, bit) in _buttons) {
      if (button == k) {
        _state[id][byte] =
            released ? _state[id][byte] | bit : _state[id][byte] & ~bit;
      }
    }
  }

  (int, int) data(int id) => (_state[id][0], _state[id][1] | 0x07);

  void saveState(StateWriter w) {
    w.section('pad');
    _state.forEach(w.ints);
  }

  void loadState(StateReader s) {
    s.section('pad');
    for (final state in _state) {
      s.intsInto(state);
    }
  }

  void reset() {
    for (final s in _state) {
      s[0] = 0xff;
      s[1] = 0xff;
    }
  }
}
