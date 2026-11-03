import '../../../pad_button.dart';
import '../../../pad_source.dart';
import '../../../util/int.dart';
import '../../../util/state.dart';

class Pad {
  static const select = PadButton("Select");
  static const run = PadButton("Run");
  static const ii = PadButton("II");
  static const i = PadButton("I");

  // In the unified key order: the X key is II, the C key is I, Enter is
  // Run and Shift is Select; the other slots are empty.
  final buttons = [
    PadButton.up,
    PadButton.down,
    PadButton.left,
    PadButton.right,
    PadButton.none,
    PadButton.none,
    ii,
    i,
    PadButton.none,
    PadButton.none,
    PadButton.none,
    PadButton.none,
    PadButton.none,
    PadButton.none,
    PadButton.none,
    PadButton.none,
    PadButton.none,
    PadButton.none,
    run,
    select,
  ];

  static const controllerNum = 5;

  /// where the held buttons are read from, set by the core
  PadSource source = const NoPadSource();

  bool selectLRDU = false; // else RunSelect12
  bool clear = false;
  int counter = 0;

  reset() {
    selectLRDU = false;
    clear = false;
    counter = 0;
  }

  /// Saves the port select lines and the controller counter.
  void saveState(StateWriter w) {
    w.section('pce-pad');
    w.int32(counter);
    w.boolean(selectLRDU);
    w.boolean(clear);
  }

  /// Restores the state written by [saveState].
  void loadState(StateReader s) {
    s.section('pce-pad');
    counter = s.int32();
    selectLRDU = s.boolean();
    clear = s.boolean();
  }

  set port(int data) {
    final newSelect = data.bit0;
    final newClear = data.bit1;
    if (newSelect && !clear && newClear) {
      counter = 0;
    } else if (!clear && !newClear && !selectLRDU && newSelect) {
      if (counter < 0xff) {
        counter++;
      }
    }
    selectLRDU = newSelect;
    clear = newClear;
  }

  int buttonValue(PadButton button, int bit) =>
      !source.isPressed(counter, button) ? bit : 0;

  int get port => counter >= controllerNum
      ? 0
      : selectLRDU
          ? buttonValue(PadButton.left, 0x08) |
              buttonValue(PadButton.down, 0x04) |
              buttonValue(PadButton.right, 0x02) |
              buttonValue(PadButton.up, 0x01)
          : buttonValue(run, 0x08) |
              buttonValue(select, 0x04) |
              buttonValue(ii, 0x02) |
              buttonValue(i, 0x01);

  String dump() {
    final joys = buttons.map(
      (j) => "${j.name}:${source.isPressed(0, j) ? "*" : "-"}",
    );
    return "$joys";
  }
}
