// Flutter imports:
import 'package:flutter/services.dart';

// Project imports:
import '../core/core_controller.dart';
import '../core/pad_button.dart';

class KeyHandler {
  final CoreController controller;
  late Map<PhysicalKeyboardKey, PadButton?> _keys;

  KeyHandler({required this.controller}) {
    init();
  }

  init() {
    maybeButton(int no) =>
        controller.buttons.length - 1 >= no ? controller.buttons[no] : null;
    _keys = {
      PhysicalKeyboardKey.arrowDown: PadButton.down,
      PhysicalKeyboardKey.arrowUp: PadButton.up,
      PhysicalKeyboardKey.arrowLeft: PadButton.left,
      PhysicalKeyboardKey.arrowRight: PadButton.right,
      PhysicalKeyboardKey.keyA: maybeButton(4),
      PhysicalKeyboardKey.keyS: maybeButton(5),
      PhysicalKeyboardKey.keyZ: maybeButton(6),
      PhysicalKeyboardKey.keyX: maybeButton(7),
      PhysicalKeyboardKey.keyC: maybeButton(8),
      PhysicalKeyboardKey.keyQ: maybeButton(9),
      PhysicalKeyboardKey.keyW: maybeButton(10),
      PhysicalKeyboardKey.keyE: maybeButton(11),
    };
  }

  bool handle(KeyEvent e) {
    final button = _keys[e.physicalKey];

    if (button != null) {
      if (e is KeyDownEvent) {
        controller.padDown(0, button);
        return true;
      } else if (e is KeyUpEvent) {
        controller.padUp(0, button);
        return true;
      }
    }

    return false;
  }
}
