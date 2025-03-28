import 'package:fnesemu/util/debug.dart';
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
  bool irqWhenTarget = false;
  bool irqWhenFfff = false;
  bool repeatMode = false;
  bool toggleMode = false;
  bool resetAfterTarget = false;
  bool sync = false;
  int syncMode = 0;
  bool sourceSystemClock = false;

  bool pause = false;
  bool triggered = false;
  int ttl = 0;

  int get mode => mode_
      .setBit(10, !intRequested)
      .setBit(11, reachTarget)
      .setBit(12, reachFfff);

  void trigger() {
    if (repeatMode || !triggered) {
      final prev = intRequested;
      if (toggleMode) {
        intRequested = !intRequested;
      } else {
        intRequested = true;
        ttl = 3;
      }

      intRequested = toggleMode ? !intRequested : true;
      triggered = true;
      if (!prev && intRequested) {
        bus.interrupt(Interrupt.timer0 + no);
      }
    }
  }

  void clock() {
    if (ttl > 0) {
      ttl--;
      if (ttl == 0) {
        intRequested = false;
      }
    }

    if (pause) {
      return;
    }

    counter++;
    counter &= 0xffff;

    if (counter == 0) {
      reachFfff = true;
      if (irqWhenFfff) {
        trigger();
      }
    }

    if (counter == target) {
      reachTarget = true;

      if (resetAfterTarget && sync) {
        counter = 0;
      }

      if (irqWhenTarget) {
        trigger();
      }
    }
  }

  void start() {
    if (!sync) {
      return;
    }

    switch (syncMode) {
      case 0:
        pause = true;
      case 1:
        counter = 0;
      case 2:
        pause = false;
        counter = 0;
      case 3:
        pause = false;
    }
  }

  void end() {
    if (!sync) {
      return;
    }

    switch (syncMode) {
      case 0:
        pause = false;
      case 2:
        pause = true;
    }
  }

  String dump() => "Timer$no: ${mode.hex16} ${counter.hex16}/${target.hex16}";
}

class TimerController {
  final Bus bus;
  late final List<Timer> timers;

  TimerController(this.bus) {
    timers = [Timer(0, bus), Timer(1, bus), Timer(2, bus)];
  }

  void startHBlank() {
    timers[0].start();

    if (!timers[1].sourceSystemClock) {
      timers[1].clock();
    }
  }

  void endHBlank() => timers[0].end();
  void startVBlank() => timers[1].start();
  void endVBlank() => timers[1].end();

  int systemClockCounter = 0;
  int dotClockCounter = 0;

  void clock() {
    if (timers[0].sourceSystemClock) {
      timers[0].clock();
    } else {
      // clock source = dotClockHz = [system clock] * 11 / gpu.dotClockDivider
      dotClockCounter += 11;
      if (dotClockCounter >= bus.gpu.dotClockDivider) {
        dotClockCounter -= bus.gpu.dotClockDivider;
        timers[0].clock();
      }
    }

    if (timers[1].sourceSystemClock) {
      timers[1].clock();
    }

    // clock source = systemClockHz/8
    if (timers[2].sourceSystemClock) {
      timers[2].clock();
    } else {
      systemClockCounter = systemClockCounter.inc & 0x07;
      if (systemClockCounter == 0) {
        timers[2].clock();
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

  void setMode(int no, int mode) {
    debugLog("Timer$no: set mode ${mode.hex32}");
    final t = timers[no];
    t.mode_ = mode;
    t.intRequested = false;
    t.sync = mode.bit0;
    t.syncMode = mode >> 1 & 0x03;
    t.resetAfterTarget = mode.bit3;
    t.irqWhenTarget = mode.bit4;
    t.irqWhenFfff = mode.bit5;
    t.repeatMode = mode.bit6;
    t.toggleMode = mode.bit7;
    t.sourceSystemClock = no == 2 ? !mode.bit9 : !mode.bit8;
    t.triggered = false;
    t.pause = no != 2 && t.sync && t.syncMode == 3;
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
