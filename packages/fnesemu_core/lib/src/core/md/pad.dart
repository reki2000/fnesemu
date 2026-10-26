// import '../../util/debug.dart';
import '../../pad_button.dart';
import '../../pad_source.dart';
import '../../util/int.dart';
import '../../util/state.dart';

// final _log = DebugLog('md.pad');

class Pad {
  /// where the held buttons are read from, set by the core
  PadSource source = const NoPadSource();

  static const controllerNum = 3;

  /// Saves logical state while the owning core identifies external media.
  void saveState(StateWriter w) {
    w.section('md-pad');
    w.ints(counter);
    w.ints(_lastEdge);
    for (var i = 0; i < controllerNum; i++) {
      w.boolean(th[i]);
    }
  }

  /// Restores existing buffers and keeps callback and bus wiring.
  void loadState(StateReader s) {
    s.section('md-pad');
    s.intsInto(counter);
    s.intsInto(_lastEdge);
    for (var i = 0; i < controllerNum; i++) {
      th[i] = s.boolean();
    }
  }

  static const _mode = PadButton("Mode");
  static const _start = PadButton("Start");
  static const _a = PadButton("A");
  static const _b = PadButton("B");
  static const _c = PadButton("C");
  static const _x = PadButton("X");
  static const _y = PadButton("Y");
  static const _z = PadButton("Z");

  /// the buttons in the order of buttonIndice
  static const _hw = [
    PadButton.up,
    PadButton.down,
    PadButton.left,
    PadButton.right,
    _mode, // 4
    _start, // 5
    _a, // 6
    _b, // 7
    _c, // 8
    _x, // 9
    _y, // 10
    _z, // 11
  ];

  /// the buttons in the order of the keys A S Z X C Q W E R D
  List<PadButton> get buttons => const [
        PadButton.up,
        PadButton.down,
        PadButton.left,
        PadButton.right,
        _x,
        _y,
        _a,
        _b,
        _c,
        _mode,
        PadButton.none,
        _start,
        PadButton.none,
        _z,
      ];

  /// the buttons read at each TH edge of the 6 button pad (bit 5 to 0): -1
  /// reads 1, -2 reads 0. TH high and low alternate from the first high.
  static const buttonIndice = [
    [8, 7, 3, 2, 1, 0], // 1st high: C B R L D U
    [5, 6, -2, -2, 1, 0], // 1st low: S A 0 0 D U
    [8, 7, 3, 2, 1, 0], // 2nd high: C B R L D U
    [5, 6, -2, -2, 1, 0], // 2nd low: S A 0 0 D U
    [8, 7, 3, 2, 1, 0], // 3rd high: C B R L D U
    [5, 6, -2, -2, -2, -2], // 3rd low: S A 0 0 0 0
    [8, 7, 4, 9, 10, 11], // 4th high: C B M X Y Z
    [5, 6, -1, -1, -1, -1], // 4th low: S A 1 1 1 1
  ];

  List<int> counter = [0, 0, 0];
  List<bool> th = [false, false, false];

  int buttonValue(int id, int index, int bit) =>
      !source.isPressed(id, _hw[index]) ? bit : 0;

  /// m68 clocks without a TH edge after which the pad returns to its first
  /// state (about 1.5 ms)
  static const timeoutClocks = 11500;

  final List<int> _lastEdge = [0, 0, 0];

  // returns to the first state of the current TH level when the timeout passed
  void _expire(int id, int clocks) {
    if (clocks - _lastEdge[id] > timeoutClocks || clocks < _lastEdge[id]) {
      counter[id] = th[id] ? 0 : 1;
    }
  }

  void writeData(int id, int val, int clocks) {
    if (th[id] != val.bit6) {
      _expire(id, clocks);
      _lastEdge[id] = clocks;
      th[id] = !th[id];
      counter[id]++;
      if (counter[id] == 8) {
        counter[id] = 0;
      }
    }
    // _log.debugc(() => "$id writeData ${val.x2} th:${th[id]} counter:${counter[id]}");
  }

  int readData(int id, int clocks) {
    _expire(id, clocks);
    final val = buttonIndice[counter[id]].fold(
        0,
        (prev, idx) =>
            prev.shl1 |
            (idx == -2
                ? 0
                : (idx == -1 || !source.isPressed(id, _hw[idx]))
                    ? 1
                    : 0));
    // _log.debugc(() =>
    //     "$id counter:${counter[id]} ${val.x2} isPressed:${isPressed[id]}");
    return val | (th[id] ? 0x40 : 0);
  }

  void writeCtrl(int id, int val) {
    if (val.bit6) {
      th[id] = true;
    }
    counter[id] = 0;
    // _log.debugc(() => "$id writeCtrl ${val.x2} th:${th[id]} counter:${counter[id]}");
  }
}
