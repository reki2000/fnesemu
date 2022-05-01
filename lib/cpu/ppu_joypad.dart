class Joypad {
  final isPressed = List.filled(8, false);
  var counter = 0;

  void keyDown(PadButton d) {
    isPressed[d.index] = true;
  }

  void keyUp(PadButton d) {
    isPressed[d.index] = false;
  }

  void reset() {
    counter = 0;
  }

  int read() {
    final result = isPressed[counter] ? 0x41 : 0x40;
    counter++;
    if (counter == 8) {
      counter = 0;
    }
    return result;
  }

  int read2() {
    return 0x40;
  }
}

enum PadButton {
  a,
  b,
  select,
  start,
  up,
  down,
  left,
  right,
}
