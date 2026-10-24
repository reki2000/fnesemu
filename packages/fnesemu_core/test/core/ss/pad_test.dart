import 'package:fnesemu_core/src/core/ss/pad.dart';
import 'package:fnesemu_core/src/pad_button.dart';
import 'package:test/test.dart';

void main() {
  test('key slots are in the order of the keyboard rows', () {
    final names = Pad().buttons.map((b) => b.name).toList();
    expect(names.sublist(4), [
      'X', 'Y', 'A', 'B', 'C', //
      'L', 'Start', 'R', '', 'Z',
    ]);
  });

  test('the R slot is empty', () {
    final pad = Pad();
    expect(pad.buttons[12], PadButton.none);
    pad.keyDown(0, pad.buttons[12]);
    expect(pad.data(0), (0xff, 0xff));
  });

  test('L, Start and R are read from their bits', () {
    final pad = Pad();
    pad.keyDown(0, pad.buttons[9]); // L
    expect(pad.data(0), (0xff, 0xf7));
    pad.keyUp(0, pad.buttons[9]);
    pad.keyDown(0, pad.buttons[10]); // Start
    expect(pad.data(0), (0xf7, 0xff));
    pad.keyUp(0, pad.buttons[10]);
    pad.keyDown(0, pad.buttons[11]); // R
    expect(pad.data(0), (0xff, 0x7f));
  });
}
