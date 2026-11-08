import '../../../pad_button.dart';
import '../../../pad_source.dart';
import '../../../util/int.dart';
import '../../../util/state.dart';

class Joypad {
  final PadSource pad;

  // In the unified key order: the X key is B, the C key is A, Enter is
  // Start and Shift is Select; the other slots are empty.
  final buttons = [
    PadButton.left,
    PadButton.right,
    PadButton.up,
    PadButton.down,
    PadButton.none,
    PadButton.none,
    const PadButton("B"),
    const PadButton("A"),
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
    const PadButton("Start"),
    const PadButton("Select"),
  ];

  final scanOrder = [
    7, // A
    6, // B
    19, // select
    18, // start
    2, // up
    3, // down
    0, // left
    1, // right
  ];

  var counter = 0;

  // the strobe (bit 0 of $4016) holds the shift register at the first button
  bool _strobe = false;

  Joypad([this.pad = const NoPadSource()]);

  /// Saves the shift register position and the strobe level.
  void saveState(StateWriter w) {
    w.section('nes-pad');
    w.int32(counter);
    w.boolean(_strobe);
  }

  /// Restores the state written by [saveState].
  void loadState(StateReader s) {
    s.section('nes-pad');
    counter = s.int32();
    _strobe = s.boolean();
  }

  void write(int addr, int data) {
    if (addr != 0x4016) return;
    _strobe = data.bit0;
    if (_strobe) counter = 0;
  }

  int read(int addr) {
    switch (addr) {
      case 0x4016:
        return _read1();
      case 0x4017:
        return _read2();
      default:
        return 0x00;
    }
  }

  // a standard pad reads 1 after its 8 buttons
  int _read1() {
    if (counter >= 8) return 0x41;
    final result = pad.isPressed(0, buttons[scanOrder[counter]]) ? 0x41 : 0x40;
    if (!_strobe) counter++;
    return result;
  }

  int _read2() {
    return 0x40;
  }

  String dump() {
    final joys =
        buttons.map((j) => "${j.name}:${pad.isPressed(0, j) ? "*" : "-"}");
    return "$joys";
  }
}
