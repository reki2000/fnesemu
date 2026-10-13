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
