import 'package:fnesemu_core/src/core/pce/component/pad.dart';
import 'package:fnesemu_core/src/core/pce/pce.dart';
import 'package:fnesemu_core/src/pad_button.dart';
import 'package:fnesemu_core/src/pad_source.dart';
import 'package:test/test.dart';

void main() {
  test('controller buttons are independent', () {
    final state = PadState();
    final pad = Pad()..source = state;
    state.press(0, pad.buttons[7]);
    pad.counter = 1;
    expect(pad.port, 0x0f);
  });

  test('the buttons are read in the order of the hardware', () {
    int read(String name, {required bool sel}) {
      final pad = Pad()
        ..source = (PadState()..press(0, pad0Button(name)))
        ..port = 3 // clear: the first controller
        ..port = sel ? 1 : 0;
      return ~pad.port & 0x0f;
    }

    expect(read('up', sel: true), 0x01);
    expect(read('right', sel: true), 0x02);
    expect(read('down', sel: true), 0x04);
    expect(read('left', sel: true), 0x08);
    expect(read('I', sel: false), 0x01);
    expect(read('II', sel: false), 0x02);
    expect(read('Select', sel: false), 0x04);
    expect(read('Run', sel: false), 0x08);
  });

  test('polling beyond five controllers does not throw', () {
    final pad = Pad();
    for (var i = 0; i < Pad.controllerNum; i++) {
      pad.port = 0;
      pad.port = 1;
    }
    expect(() => pad.port, returnsNormally);
    expect(pad.port, 0);
  });

  test('controller scan advances only on a select rising edge', () {
    final pad = Pad();
    pad.port = 3;
    pad.port = 1;
    expect(pad.counter, 0);
    pad.port = 0;
    pad.port = 1;
    pad.port = 1;
    expect(pad.counter, 1);
  });

  test('clear can be asserted again after it is released', () {
    final pad = Pad();
    pad.port = 3;
    pad.port = 0;
    pad.port = 1;
    expect(pad.counter, 1);
    pad.port = 3;
    expect(pad.counter, 0);
  });

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

  test('core reset restores controller selection and clear state', () {
    final pce = Pce();
    pce.bus.joypad.port = 3;
    pce.bus.joypad.port = 0;
    pce.bus.joypad.port = 1;
    pce.reset();
    expect(pce.bus.joypad.counter, 0);
    expect(pce.bus.joypad.selectLRDU, isFalse);
    expect(pce.bus.joypad.clear, isFalse);
  });

  test('controller counter saturates safely during extended polling', () {
    final pad = Pad();
    for (var i = 0; i < 300; i++) {
      pad.port = 0;
      pad.port = 1;
    }
    expect(pad.counter, 0xff);
    expect(pad.port, 0);
  });
}

PadButton pad0Button(String name) =>
    Pad().buttons.firstWhere((b) => b.name == name);
