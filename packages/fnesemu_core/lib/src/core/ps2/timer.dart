import 'intc.dart';
import 'state.dart';

/// The four EE timers. Counters are 16 bits wide and tick at the bus clock
/// (half the CPU clock) divided by 1, 16 or 256, or at each horizontal blank.
///
/// Gate control (MODE bits 2..5) is not implemented: a timer with the gate
/// enabled counts as if it were open.
class EeTimers {
  static const baseAddress = 0x10000000;

  static const _enable = 1 << 7, _zeroReturn = 1 << 6;
  static const _compareInterrupt = 1 << 8, _overflowInterrupt = 1 << 9;
  static const _compareFlag = 1 << 10, _overflowFlag = 1 << 11;
  static const _divisors = [1, 16, 256];

  final Intc intc;
  final count = List<int>.filled(4, 0);
  final mode = List<int>.filled(4, 0);
  final compare = List<int>.filled(4, 0);
  final hold = List<int>.filled(4, 0);
  final _prescale = List<int>.filled(4, 0);

  EeTimers(this.intc);

  static bool handles(int address) =>
      address >= baseAddress && address < baseAddress + 0x2000;

  // The timers take the clocks lazily. [_pendingClocks] collects them until
  // they reach [_quietClocks], the bus clocks before the first timer could
  // reach its compare value or overflow, or until a register is accessed.
  // The counts and the interrupts are the same as with an update on every
  // call.
  int _pendingClocks = 0, _quietClocks = 0;

  void saveState(StateWriter w) {
    for (final list in [count, mode, compare, hold, _prescale]) {
      w.ints(list);
    }
    w.ints([_pendingClocks, _quietClocks]);
  }

  void loadState(StateReader s) {
    for (final list in [count, mode, compare, hold, _prescale]) {
      s.intsInto(list);
    }
    final v = s.fields(2, 'timer');
    _pendingClocks = v[0];
    _quietClocks = v[1];
  }

  /// advances the timers by [busClocks] bus clock cycles
  void advance(int busClocks) {
    _pendingClocks += busClocks;
    if (_pendingClocks >= _quietClocks) _flush();
  }

  void _flush() {
    final busClocks = _pendingClocks;
    _pendingClocks = 0;
    if (busClocks != 0) _advance(busClocks);
    _quietClocks = _quiet();
  }

  /// the bus clocks before the first timer that counts them reaches its
  /// compare value or overflows
  int _quiet() {
    var quiet = 1 << 40;
    for (var t = 0; t < 4; t++) {
      final m = mode[t];
      if (m & _enable == 0) continue;
      final select = m & 3;
      if (select == 3) continue;
      final c = count[t], comp = compare[t];
      var ticks = 0x10000 - c;
      if (comp > c && comp - c < ticks) ticks = comp - c;
      final clocks = ticks * _divisors[select] - _prescale[t];
      if (clocks < quiet) quiet = clocks;
    }
    return quiet;
  }

  void _advance(int busClocks) {
    for (var t = 0; t < 4; t++) {
      final m = mode[t];
      if (m & _enable == 0) continue;
      final select = m & 3;
      if (select == 3) continue;
      final divisor = _divisors[select];
      _prescale[t] += busClocks;
      final ticks = _prescale[t] ~/ divisor;
      _prescale[t] -= ticks * divisor;
      if (ticks > 0) _tick(t, ticks);
    }
  }

  /// counts one horizontal blank for the timers that use it as their clock
  void hblank() {
    for (var t = 0; t < 4; t++) {
      if (mode[t] & _enable != 0 && mode[t] & 3 == 3) _tick(t, 1);
    }
  }

  void _tick(int t, int ticks) {
    var remaining = ticks;
    var c = count[t];
    final comp = compare[t];
    while (remaining > 0) {
      final toOverflow = 0x10000 - c;
      final toCompare = comp > c ? comp - c : 0x7fffffff;
      final step = remaining < toOverflow
          ? (remaining < toCompare ? remaining : toCompare)
          : (toOverflow < toCompare ? toOverflow : toCompare);
      remaining -= step;
      c += step;
      if (c == comp) {
        _event(t, _compareFlag, _compareInterrupt);
        if (mode[t] & _zeroReturn != 0) c = 0;
      }
      if (c == 0x10000) {
        c = 0;
        _event(t, _overflowFlag, _overflowInterrupt);
        if (c == comp) _event(t, _compareFlag, _compareInterrupt);
      }
    }
    count[t] = c;
  }

  void _event(int t, int flag, int enableBit) {
    mode[t] |= flag;
    if (mode[t] & enableBit != 0) intc.raise(Intc.timer0 + t);
  }

  int read(int address) {
    _flush();
    final t = (address >> 11) & 3;
    switch ((address >> 4) & 15) {
      case 0:
        return count[t];
      case 1:
        return mode[t];
      case 2:
        return compare[t];
      case 3:
        return t < 2 ? hold[t] : 0;
    }
    return 0;
  }

  void write(int address, int value) {
    _flush();
    final t = (address >> 11) & 3;
    switch ((address >> 4) & 15) {
      case 0:
        count[t] = value & 0xffff;
      case 1:
        // the compare and overflow flags clear when written with 1
        final flags = mode[t] & (_compareFlag | _overflowFlag);
        mode[t] = (value & 0x3ff) | (flags & ~value);
      case 2:
        compare[t] = value & 0xffff;
    }
    _quietClocks = _quiet();
  }
}
