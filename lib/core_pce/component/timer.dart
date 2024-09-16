import 'bus.dart';

class Timer {
  late final Bus bus;

  Timer(this.bus) {
    bus.timer = this;
  }

  static const prescalerSize = 1024;
  int prescaler = 0;
  int size = 0;
  int counter = 0;
  bool enabled = false;

  reset() {
    prescaler = 0;
    size = 0;
    counter = 0;
    enabled = false;
  }

  exec(int elapsedClocks) {
    prescaler -= (elapsedClocks ~/ 3);

    if (prescaler < 0) {
      prescaler += prescalerSize;

      if (enabled) {
        counter--;

        if (counter < 0) {
          counter = size;
          bus.holdTirq();
        }
      }
    }
  }

  trigger(bool onoff) {
    enabled = onoff;
    if (onoff) {
      counter = size;
    }
  }
}
