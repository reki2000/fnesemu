// Flutter imports:
import 'package:flutter/services.dart';

// Project imports:
import 'nes_controller.dart';

class KeyHandler {
  KeyHandler({required this.controller});

  final NesController controller;

  static final _keys = {
    PhysicalKeyboardKey.arrowDown: NesPadButton.down,
    PhysicalKeyboardKey.arrowUp: NesPadButton.up,
    PhysicalKeyboardKey.arrowLeft: NesPadButton.left,
    PhysicalKeyboardKey.arrowRight: NesPadButton.right,
    PhysicalKeyboardKey.keyX: NesPadButton.a,
    PhysicalKeyboardKey.keyZ: NesPadButton.b,
    PhysicalKeyboardKey.keyA: NesPadButton.select,
    PhysicalKeyboardKey.keyS: NesPadButton.start,
  };

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
