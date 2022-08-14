import 'package:flutter/services.dart';

import 'nes_controller.dart';

class KeyHandler {
  final NesController controller;
  KeyHandler({required this.controller});

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
    NesPadButton? button = _keys[e.physicalKey];
    if (button != null) {
      switch (e.runtimeType) {
        case KeyDownEvent:
          controller.padDown(button);
          return true;
        case KeyUpEvent:
          controller.padUp(button);
          return true;
      }
    }
    return false;
  }
}
