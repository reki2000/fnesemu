import 'package:fnesemu/util/int.dart';

import 'irq.dart';

/// GBA timers (4 channels, registers 0x4000100..0x400010F).
///
/// Each channel has a 16-bit counter that increments either every N CPU cycles
/// (prescaler) or on the previous channel's overflow (count-up cascade). On
/// overflow the counter reloads from the latched reload value and optionally
/// raises an interrupt.
class Timers {
  final Irq irq;
  Timers(this.irq);

  /// invoked on each overflow with (timerId, overflowCount); used by the APU
  /// to advance the Direct Sound FIFOs.
  void Function(int timerId, int count)? onOverflow;

  final _counter = List<int>.filled(4, 0); // current 16-bit value
  final _reload = List<int>.filled(4, 0); // reload value (TMxCNT_L writes)
  final _control = List<int>.filled(4, 0); // TMxCNT_H
  final _sub = List<int>.filled(4, 0); // accumulated prescaler sub-cycles

  // prescaler shift: 1, 64, 256, 1024 cycles per tick
  static const _prescalerShift = [0, 6, 8, 10];

  bool _enabled(int ch) => _control[ch].bit7;
  bool _countUp(int ch) => ch != 0 && _control[ch].bit2;
  bool _irqEnable(int ch) => _control[ch].bit6;

  /// supply [cycles] of elapsed CPU time to the prescaler-driven channels.
  void tick(int cycles) {
    for (int ch = 0; ch < 4; ch++) {
      if (!_enabled(ch) || _countUp(ch)) continue;
      final shift = _prescalerShift[_control[ch] & 3];
      _sub[ch] += cycles;
      final ticks = _sub[ch] >> shift;
      if (ticks > 0) {
        _sub[ch] -= ticks << shift;
        _increment(ch, ticks);
      }
    }
  }

  void _increment(int ch, int amount) {
    int c = _counter[ch] + amount;
    if (c <= 0xffff) {
      _counter[ch] = c;
      return;
    }
    final reload = _reload[ch];
    final period = 0x10000 - reload;
    final excess = c - 0x10000;
    final overflows = 1 + excess ~/ period;
    _counter[ch] = reload + excess % period;
    _onOverflow(ch, overflows);
  }

  void _onOverflow(int ch, int count) {
    if (_irqEnable(ch)) irq.raise(IrqBit.timer0 + ch);
    onOverflow?.call(ch, count);
    // cascade into the next channel if it is in count-up mode
    if (ch < 3 && _enabled(ch + 1) && _countUp(ch + 1)) {
      _increment(ch + 1, count);
    }
  }

  // --- register access (offset is reg & 0xf within 0x100..0x10f) ------------

  int read16(int reg) {
    final ch = (reg & 0xf) >> 2;
    return (reg & 2) != 0 ? _control[ch] : _counter[ch];
  }

  void write16(int reg, int data) {
    final ch = (reg & 0xf) >> 2;
    if ((reg & 2) == 0) {
      _reload[ch] = data & 0xffff;
      return;
    }
    final wasEnabled = _enabled(ch);
    _control[ch] = data & 0xffff;
    if (!wasEnabled && _enabled(ch)) {
      _counter[ch] = _reload[ch];
      _sub[ch] = 0;
    }
  }

  void reset() {
    for (int ch = 0; ch < 4; ch++) {
      _counter[ch] = 0;
      _reload[ch] = 0;
      _control[ch] = 0;
      _sub[ch] = 0;
    }
  }
}
