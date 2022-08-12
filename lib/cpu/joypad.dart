// Project imports:
import 'pad_button.dart';
import 'util.dart';

class Joypad {
  final isPressed = List.filled(8, false);
  var counter = 0;

  void keyDown(PadButton d) {
    isPressed[d.index] = true;
  }

  void keyUp(PadButton d) {
    isPressed[d.index] = false;
  }

  void _reset1() {
    counter = 0;
  }

  void write(int addr, int data) {
    if (bit0(data)) {
      return;
    }

    switch (addr) {
      case 0x4016:
        _reset1();
        break;
      case 0x04017:
        break;
    }
  }

  int read(int addr) {
    switch (addr) {
      case 0x4016:
        return _read1();
      case 0x4017:
        return _read2();
      default:
        return 0x00;
    }
  }

  int _read1() {
    final result = isPressed[counter] ? 0x41 : 0x40;
    counter++;
    if (counter == 8) {
      counter = 0;
    }
    return result;
  }

  int _read2() {
    return 0x40;
  }

  String dump({showSpriteVram = false}) {
    final joys = PadButton.values
        .map((j) => "${j.name}:${isPressed[j.index] ? "*" : "-"}");
    return "$joys";
  }
}
