import 'package:fnesemu/util/int.dart';

import 'bus.dart';
import 'interrupt.dart';

class Timer {
  final int no;
  final Bus bus;

  Timer(this.no, this.bus);

  int counter = 0;
  int target = 0;
  int mode_ = 0;

  bool reachTarget = false;
  bool reachFfff = false;
  bool intRequested = false;
  bool sync = false;

  int get _syncMode => mode_ >> 1 & 0x03;
  bool get _resetAfterTarget => mode_.bit3;
  bool get _irqWhenTarget => mode_.bit4;
  bool get _irqWhenFfff => mode_.bit5;
  bool get _repeatMode => mode_.bit6;
  bool get _toggleMode => mode_.bit7;

  bool pause = false;
  bool triggered = false;

  void reset() {
    counter = 0;
    target = 0;
    mode_ = 0;

    reachTarget = false;
    reachFfff = false;
    intRequested = false;
    sync = false;

    pause = false;
    triggered = false;
  }

  int get mode => mode_
      .setBit(10, !intRequested)
      .setBit(11, reachTarget)
      .setBit(12, reachFfff);

  void trigger() {
    if (_toggleMode) {
      intRequested = !intRequested;
    } else {
      intRequested = true;
    }
  }

  void clock(int cycles) {
    if (!_toggleMode && intRequested) {
      intRequested = false;
    }

    if (pause) {
      return;
    }

    counter += cycles;

    if (counter > 0xffff) {
      if (_irqWhenFfff) {
        trigger();
      }

      reachFfff = true;
      counter &= 0xffff;
    } else if (counter >= target && (counter - cycles) < target) {
      if (_irqWhenTarget) {
        trigger();
      }

      reachTarget = true;
      if (_resetAfterTarget) {
        counter -= target;
      }
    }

    if (intRequested && (_repeatMode || !triggered)) {
      bus.setIrq(Interrupt.timer0 + no);
      triggered = true;
    }
  }

  void start() {
    if (!sync) {
      return;
    }

    switch (_syncMode) {
      case 0:
        pause = true;
      case 1:
        counter = 0;
      case 2:
        pause = false;
        counter = 0;
      case 3:
        pause = false;
        sync = false;
    }
  }

  void end() {
    if (!sync) {
      return;
    }

    switch (_syncMode) {
      case 0:
        pause = false;
      case 2:
        pause = true;
    }
  }

  String dump() => "Timer$no: ${mode.hex16} ${counter.hex16}/${target.hex16} "
      "sy:${!sync ? '-' : _syncMode} ${(no == 2 ? !mode_.bit9 : !mode_.bit8) ? 'S' : 'E'} "
      "${_repeatMode ? "rep" : "one"} ${_toggleMode ? "tgl" : "pls"} "
      "${_resetAfterTarget ? "0" : "-"} "
      "i:${_irqWhenTarget ? "T" : "-"}${_irqWhenFfff ? "F" : "-"}";
}

class TimerController {
  final Bus bus;
  late final List<Timer> timers;

  TimerController(this.bus) {
    timers = [Timer(0, bus), Timer(1, bus), Timer(2, bus)];
  }

  void reset() {
    for (final t in timers) {
      t.reset();
    }
  }

  void startHBlank() {
    timers[0].start();

    if (timers[1].mode_.bit8) {
      timers[1].clock(1);
    }
  }

  void endHBlank() => timers[0].end();
  void startVBlank() => timers[1].start();
  void endVBlank() => timers[1].end();

  int systemClockCounter = 0;
  int dotClockCounter = 0;

  void clock(int cycles) {
    if (!timers[0].mode_.bit8) {
      timers[0].clock(cycles);
    } else {
      // clock source = dotClockHz = [system clock] * 11 / gpu.dotClockDivider
      dotClockCounter += 11 * cycles;
      if (dotClockCounter >= bus.gpu.dotClockDivider) {
        timers[0].clock(dotClockCounter ~/ bus.gpu.dotClockDivider);
        dotClockCounter %= bus.gpu.dotClockDivider;
      }
    }

    if (!timers[1].mode_.bit8) {
      timers[1].clock(cycles);
    }

    if (!timers[2].mode_.bit9) {
      timers[2].clock(cycles);
    } else {
      // clock source = systemClockHz/8
      systemClockCounter += cycles;
      if (systemClockCounter >= 8) {
        timers[2].clock(systemClockCounter ~/ 8);
        systemClockCounter &= 0x07;
      }
    }
  }

  int mode(int no) {
    final t = timers[no];
    final result = t.mode;
    t.reachTarget = false;
    t.reachFfff = false;
    return result;
  }

  void setMode(int no, int newMode) {
    // debugLog("Timer$no: set mode ${mode.hex32}");
    final t = timers[no];
    t.mode_ = newMode;
    t.sync = newMode.bit0;
    t.pause = no == 2 && t.sync && (t._syncMode == 3 || t._syncMode == 0);

    t.triggered = false;
    t.intRequested = false;
    t.counter = 0;
    t.reachTarget = false;
    t.reachFfff = false;
  }

  int target(int no) => timers[no].target;
  void setTarget(int no, int target) {
    final t = timers[no];
    t.target = target.mask16;
    t.reachTarget = false;
    t.reachFfff = false;
  }

  int counter(int no) => timers[no].counter;
  void setCounter(int no, int value) {
    final t = timers[no];
    t.counter = value.mask16;
    t.reachTarget = false;
    t.reachFfff = false;
  }
}
