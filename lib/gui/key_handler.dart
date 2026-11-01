import 'package:flutter/services.dart';

import 'package:fnesemu_core/app_api.dart';
import 'pad_input.dart';

/// Maps the keyboard to the controller of the running core.
///
/// The buttons of a core are in the unified key order (see the `buttons`
/// documentation of the core API): the arrow keys are the directional pad,
/// Enter is the start slot, Shift is the select slot, and the remaining
/// slots are, in list order, S Z X C / A D W / Q E / 1 2 3 4 / R, where R
/// is the core-specific action. The analog sticks are driven by IJKL (left)
/// and TFGH (right); those keys belong to the sticks, not to the buttons.
class KeyHandler {
  final CoreController controller;
  final PadInput input;
  late Map<PhysicalKeyboardKey, PadButton?> _keys;
  late Map<PhysicalKeyboardKey, Map<PadAxis, double>> _axisKeys;

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
      PhysicalKeyboardKey.keyS: maybeButton(4),
      PhysicalKeyboardKey.keyZ: maybeButton(5),
      PhysicalKeyboardKey.keyX: maybeButton(6),
      PhysicalKeyboardKey.keyC: maybeButton(7),
      PhysicalKeyboardKey.keyA: maybeButton(8),
      PhysicalKeyboardKey.keyD: maybeButton(9),
      PhysicalKeyboardKey.keyW: maybeButton(10),
      PhysicalKeyboardKey.keyQ: maybeButton(11),
      PhysicalKeyboardKey.keyE: maybeButton(12),
      PhysicalKeyboardKey.digit1: maybeButton(13),
      PhysicalKeyboardKey.digit2: maybeButton(14),
      PhysicalKeyboardKey.digit3: maybeButton(15),
      PhysicalKeyboardKey.digit4: maybeButton(16),
      PhysicalKeyboardKey.keyR: maybeButton(17),
      PhysicalKeyboardKey.enter: maybeButton(18),
      PhysicalKeyboardKey.numpadEnter: maybeButton(18),
      PhysicalKeyboardKey.shiftLeft: maybeButton(19),
      PhysicalKeyboardKey.shiftRight: maybeButton(19),
    };

    // The stick keys, one axis value per key. Only the axes the core
    // exposes are bound.
    _axisKeys = {};
    void bind(PhysicalKeyboardKey key, PadAxis axis, double value) {
      if (controller.axes.contains(axis)) _axisKeys[key] = {axis: value};
    }

    bind(PhysicalKeyboardKey.keyI, PadAxis.leftY, -1);
    bind(PhysicalKeyboardKey.keyK, PadAxis.leftY, 1);
    bind(PhysicalKeyboardKey.keyJ, PadAxis.leftX, -1);
    bind(PhysicalKeyboardKey.keyL, PadAxis.leftX, 1);
    bind(PhysicalKeyboardKey.keyT, PadAxis.rightY, -1);
    bind(PhysicalKeyboardKey.keyG, PadAxis.rightY, 1);
    bind(PhysicalKeyboardKey.keyF, PadAxis.rightX, -1);
    bind(PhysicalKeyboardKey.keyH, PadAxis.rightX, 1);
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

    final axisValues = _axisKeys[e.physicalKey];
    if (axisValues != null) {
      if (e is KeyDownEvent) {
        input.setAxisSource(e.physicalKey, axisValues);
      } else if (e is KeyUpEvent) {
        input.setAxisSource(e.physicalKey, {});
      }
      return true;
    }

    return false;
  }
}
