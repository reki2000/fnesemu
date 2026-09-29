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

  int get _syncMode => mode_.shr1 & 0x03;
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

  void clock(int cycles) {
    if (!_toggleMode && intRequested) {
      intRequested = false;
    }

    if (pause) {
      return;
    }

    final prev = counter;
    int next = prev + cycles;
    bool hitTarget = false;
    bool hitFfff = false;

    if (_resetAfterTarget && prev <= target) {
      // counts 0..target, then wraps to 0
      if (next >= target && (prev < target || cycles > target)) {
        hitTarget = true;
      }
      if (next > target) {
        next %= target + 1;
      }
    } else {
      // counts up to 0xffff, then wraps to 0
      if (prev < target && next >= target) {
        hitTarget = true;
      }
      if (prev < 0xffff && next >= 0xffff) {
        hitFfff = true;
      }
      if (next > 0xffff) {
        next -= 0x10000;
        if (next >= target) {
          hitTarget = true;
          if (_resetAfterTarget) {
            next %= target + 1;
          }
        }
      }
    }

    counter = next;
    reachTarget |= hitTarget;
    reachFfff |= hitFfff;

    if ((hitTarget && _irqWhenTarget) || (hitFfff && _irqWhenFfff)) {
      if (_toggleMode) {
        intRequested = !intRequested;
      } else {
        intRequested = true;
      }

      if (intRequested && (_repeatMode || !triggered)) {
        bus.setIrq(Interrupt.timer0 + no);
        triggered = true;
      }
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

  String dump() => "Timer$no: ${mode.x4} ${counter.x4}/${target.x4} "
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
    _lastClocks = 0;
    systemClockCounter = 0;
    dotClockCounter = 0;
  }

  int _lastClocks = 0;

  /// advances all timers up to the current cpu clock
  void catchUp() {
    final now = bus.cpu.clocks;
    if (now > _lastClocks) {
      clock(now - _lastClocks);
    }
    _lastClocks = now;
  }

  void startHBlank() {
    catchUp();
    timers[0].start();

    if (timers[1].mode_.bit8) {
      timers[1].clock(1);
    }
  }

  void endHBlank() {
    catchUp();
    timers[0].end();
  }

  void startVBlank() {
    catchUp();
    timers[1].start();
  }

  void endVBlank() {
    catchUp();
    timers[1].end();
  }

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

  int mode(int no, {bool clearFlags = true}) {
    catchUp();
    final t = timers[no];
    final result = t.mode;
    if (clearFlags) {
      t.reachTarget = false;
      t.reachFfff = false;
    }
    return result;
  }

  void setMode(int no, int newMode) {
    // debugLog("Timer$no: set mode ${mode.x8}");
    catchUp();
    final t = timers[no];
    t.mode_ = newMode;
    t.sync = newMode.bit0;
    t.pause = switch (no) {
      0 || 1 => t.sync && t._syncMode == 3,
      2 => t.sync && (t._syncMode == 3 || t._syncMode == 0),
      _ => false
    };

    t.triggered = false;
    t.intRequested = false;
    t.counter = 0;
    t.reachTarget = false;
    t.reachFfff = false;
  }

  int target(int no) => timers[no].target;
  void setTarget(int no, int target) {
    catchUp();
    final t = timers[no];
    t.target = target.mask16;
    t.reachTarget = false;
    t.reachFfff = false;
  }

  int counter(int no) {
    catchUp();
    return timers[no].counter;
  }

  void setCounter(int no, int value) {
    catchUp();
    final t = timers[no];
    t.counter = value.mask16;
    t.reachTarget = false;
    t.reachFfff = false;
  }
}
