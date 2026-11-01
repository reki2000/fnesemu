import 'package:fnesemu_core/src/core/ss/pad.dart';
import 'package:fnesemu_core/src/pad_button.dart';
import 'package:fnesemu_core/src/pad_source.dart';
import 'package:test/test.dart';

void main() {
  test('key slots are in the unified key order', () {
    final names = Pad().buttons.map((b) => b.name).toList();
    expect(names.sublist(4), [
      'Y', 'A', 'B', 'C', // S Z X C
      'X', 'Z', '', // A D W
      'L', 'R', // Q E
      '', '', '', '', // 1 2 3 4
      '', // R
      'Start', '', // Enter Shift
    ]);
  });

  test('the R slot is empty', () {
    final state = PadState();
    final pad = Pad()..source = state;
    expect(pad.buttons[17], PadButton.none);
    state.press(0, pad.buttons[17]);
    expect(pad.data(0), (0xff, 0xff));
  });

  test('L, Start and R are read from their bits', () {
    final state = PadState();
    final pad = Pad()..source = state;
    state.press(0, pad.buttons[11]); // L
    expect(pad.data(0), (0xff, 0xf7));
    state.release(0, pad.buttons[11]);
    state.press(0, pad.buttons[18]); // Start
    expect(pad.data(0), (0xf7, 0xff));
    state.release(0, pad.buttons[18]);
    state.press(0, pad.buttons[12]); // R
    expect(pad.data(0), (0xff, 0x7f));
  });
}
