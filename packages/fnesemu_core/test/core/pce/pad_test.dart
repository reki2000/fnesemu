import 'package:fnesemu_core/src/core/pce/component/pad.dart';
import 'package:fnesemu_core/src/core/pce/pce.dart';
import 'package:fnesemu_core/src/pad_button.dart';
import 'package:fnesemu_core/src/pad_source.dart';
import 'package:test/test.dart';

void main() {

  test('all five controllers can be read through a port scan', () {
    final state = PadState();
    final pad = Pad()..source = state;
    state.press(2, pad.buttons[7]);
    pad.port = 3;
    for (var i = 0; i < Pad.controllerNum; i++) {
      pad.port = 0;
      expect(pad.port, i == 2 ? 0x0e : 0x0f); // I is bit 0
      pad.port = 1;
    }
    expect(pad.port, 0);
  });

}

PadButton pad0Button(String name) =>
    Pad().buttons.firstWhere((b) => b.name == name);
