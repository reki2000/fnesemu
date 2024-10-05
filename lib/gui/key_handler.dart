// Flutter imports:
import 'package:flutter/services.dart';

// Project imports:
import '../core/core_controller.dart';
import '../core/pad_button.dart';

class KeyHandler {
  KeyHandler({required this.controller}) {
    init();
  }

  init() {
    _keys = {
      PhysicalKeyboardKey.arrowDown: PadButton.down,
      PhysicalKeyboardKey.arrowUp: PadButton.up,
      PhysicalKeyboardKey.arrowLeft: PadButton.left,
      PhysicalKeyboardKey.arrowRight: PadButton.right,
      PhysicalKeyboardKey.keyA: controller.buttons[4],
      PhysicalKeyboardKey.keyS: controller.buttons[5],
      PhysicalKeyboardKey.keyZ: controller.buttons[6],
      PhysicalKeyboardKey.keyX: controller.buttons[7],
    };
  }

  final CoreController controller;
  late Map<PhysicalKeyboardKey, PadButton> _keys;

  bool handle(KeyEvent e) {
    var button = _keys[e.physicalKey];

    if (button != null) {
      if (e is KeyDownEvent) {
        controller.padDown(button);
        return true;
      } else if (e is KeyUpEvent) {
        controller.padUp(button);
        return true;
      }
    }

    return false;
  }
}
