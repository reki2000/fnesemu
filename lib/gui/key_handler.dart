// Flutter imports:
import 'package:flutter/services.dart';

// Project imports:
import '../core/core_api.dart';
import 'pad_input.dart';

class KeyHandler {
  final CoreController controller;
  final PadInput input;
  late Map<PhysicalKeyboardKey, PadButton?> _keys;

  KeyHandler({required this.controller, required this.input}) {
    init();
  }

  init() {
    PadButton? maybeButton(int no) {
      if (no >= controller.buttons.length) return null;
      final button = controller.buttons[no];
      return button == PadButton.none ? null : button;
    }

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
      PhysicalKeyboardKey.keyR: maybeButton(12),
      PhysicalKeyboardKey.keyD: maybeButton(13),
    };
  }

  bool handle(KeyEvent e) {
    final button = _keys[e.physicalKey];

    if (button != null) {
      if (e is KeyDownEvent) {
        input.setSource(e.physicalKey, {button});
      } else if (e is KeyUpEvent) {
        input.setSource(e.physicalKey, {});
      }
      return true;
    }

    return false;
  }
}
