// Project imports:
import '../../util.dart';
import '../pad_button.dart';

class Pad {
  final isPressed = List.filled(8, false);

  bool selectLRDU = false; // else RunSelect12
  bool clear = false;

  void keyDown(PadButton d) {
    isPressed[d.index] = true;
  }

  void keyUp(PadButton d) {
    isPressed[d.index] = false;
  }

  reset() {
    selectLRDU = false;
  }

  set port(int data) {
    selectLRDU = bit0(data);
    clear = bit1(data);
  }

  int get port => selectLRDU
      ? (!isPressed[PadButton.left.index] ? 0x08 : 0) |
          (!isPressed[PadButton.down.index] ? 0x04 : 0) |
          (!isPressed[PadButton.right.index] ? 0x02 : 0) |
          (!isPressed[PadButton.up.index] ? 0x01 : 0)
      : (!isPressed[PadButton.start.index] ? 0x08 : 0) |
          (!isPressed[PadButton.select.index] ? 0x04 : 0) |
          (!isPressed[PadButton.a.index] ? 0x02 : 0) |
          (!isPressed[PadButton.b.index] ? 0x01 : 0);

  String dump({showSpriteVram = false}) {
    final joys = PadButton.values
        .map((j) => "${j.name}:${isPressed[j.index] ? "*" : "-"}");
    return "$joys";
  }
}
