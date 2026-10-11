import 'dart:collection';
import '../../../util/int.dart';

/// Three-entry PWM FIFOs, clocked by the SH-2 clock divider.
class ExpansionPwm {
  final left = Queue<int>(), right = Queue<int>();
  final void Function() interrupt;
  ExpansionPwm(this.interrupt);
  int control = 0, cycle = 0, _phase = 0, _irqCounter = 0;
  int _left = 0, _right = 0;
  void reset() {
    left.clear();
    right.clear();
    control = cycle = _phase = _irqCounter = _left = _right = 0;
  }

  int _status(Queue<int> fifo) =>
      (fifo.length == 3 ? 0x8000 : 0) | (fifo.isEmpty ? 0x4000 : 0);
  int read(int offset) => switch (offset) {
        0 => control,
        2 => cycle,
        4 => _status(left),
        6 => _status(right),
        8 => _status(left) | _status(right),
        _ => 0,
      };
  void write(int offset, int value) {
    value &= 0xfff;
    void enqueue(Queue<int> fifo) {
      if (fifo.length < 3) fifo.addLast(value);
    }

    switch (offset) {
      case 0:
        control = value & 0xf8f;
      case 2:
        cycle = value;
        _phase = 0;
      case 4:
        enqueue(left);
      case 6:
        enqueue(right);
      case 8:
        enqueue(left);
        enqueue(right);
    }
  }

  void tick(int clocks) {
    final period = (cycle - 1).mask12;
    if (period == 0) return;
    _phase += clocks;
    while (_phase >= period) {
      _phase -= period;
      if (left.isNotEmpty) _left = left.removeFirst();
      if (right.isNotEmpty) _right = right.removeFirst();
      _irqCounter++;
      final interval = control.shr8.mask4;
      if (_irqCounter >= (interval == 0 ? 16 : interval)) {
        _irqCounter = 0;
        interrupt();
      }
    }
  }

  (double, double) sample() {
    final period = (cycle - 1).mask12;
    if (period == 0) return (0, 0);
    double convert(int value) => ((value * 2 / period) - 1).clamp(-1.0, 1.0);
    double route(int mode, int a, int b) =>
        switch (mode) { 1 => convert(a), 2 => convert(b), _ => 0 };
    return (
      route(control.mask2, _left, _right),
      route(control.shr2.mask2, _right, _left)
    );
  }
}
