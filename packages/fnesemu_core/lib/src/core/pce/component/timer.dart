import '../../../util/state.dart';
import 'bus.dart';

class Timer {
  late final Bus bus;

  Timer(this.bus) {
    bus.timer = this;
  }

  static const prescalerSize = 1024;
  int prescaler = prescalerSize;
  int size = 0;
  int counter = 0;
  bool enabled = false;

  reset() {
    prescaler = prescalerSize;
    size = 0;
    counter = 0;
    enabled = false;
  }

  /// Saves the prescaler phase, the reload value and the counter.
  void saveState(StateWriter w) {
    w.section('pce-timer');
    w.ints([prescaler, size, counter]);
    w.boolean(enabled);
  }

  /// Restores the state written by [saveState].
  void loadState(StateReader s) {
    s.section('pce-timer');
    final v = s.ints();
    if (v.length != 3) throw const StateMismatch('timer state layout');
    prescaler = v[0];
    size = v[1];
    counter = v[2];
    enabled = s.boolean();
  }

  exec(int elapsedClocks) {
    prescaler -= (elapsedClocks ~/ 3);

    while (prescaler <= 0) {
      prescaler += prescalerSize;

      if (enabled) {
        counter--;

        if (counter < 0) {
          counter = size;
          bus.pic.holdTirq();
        }
      }
    }
  }

  trigger(bool onoff) {
    if (onoff && !enabled) {
      counter = size;
      prescaler = prescalerSize;
    }
    enabled = onoff;
  }
}
