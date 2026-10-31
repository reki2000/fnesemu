import 'dart:typed_data';

import '../../state.dart';

import 'fault.dart';

/// SH7750 TMU channels 0-2, driven explicitly in peripheral-clock units.
class DcTmu {
  final _constant = Uint32List(3);
  final _counter = Uint32List(3);
  final _control = Uint16List(3);
  int _output = 0, _start = 0, _phase = 0;

  DcTmu() {
    reset();
  }

  void reset() {
    _constant.fillRange(0, 3, 0xffffffff);
    _counter.fillRange(0, 3, 0xffffffff);
    _control.fillRange(0, 3, 0);
    _output = _start = _phase = 0;
  }

  void saveState(StateWriter writer) {
    writer.section('dc.sh4.tmu');
    for (final buffer in [_constant, _counter, _control]) {
      writer.ints(buffer);
    }
    writer.ints([_output, _start, _phase]);
  }

  void loadState(StateReader reader) {
    reader.section('dc.sh4.tmu');
    final constant = reader.ints(),
        counter = reader.ints(),
        control = reader.ints();
    final values = reader.ints();
    if (constant.length != 3 ||
        counter.length != 3 ||
        control.length != 3 ||
        [...constant, ...counter]
            .any((value) => value < 0 || value > 0xffffffff) ||
        control.any(
            (value) => value < 0 || value & ~0x13f != 0 || value & 7 >= 5) ||
        values.length != 3 ||
        values[0] < 0 ||
        values[0] > 1 ||
        values[1] < 0 ||
        values[1] > 7 ||
        values[2] < 0 ||
        values[2] >= 1024) {
      throw const StateMismatch('SH4 timer state');
    }
    _constant.setAll(0, constant);
    _counter.setAll(0, counter);
    _control.setAll(0, control);
    _output = values[0];
    _start = values[1];
    _phase = values[2];
  }

  bool interruptPending(int channel) => _control[channel] & 0x120 == 0x120;

  int read(int offset, int size) {
    if (offset == 0 && size == 1) return _output;
    if (offset == 4 && size == 1) return _start;
    if (offset == 0x2c && size == 4) return 0;
    for (var channel = 0; channel < 3; channel++) {
      final base = 8 + channel * 12;
      if (offset == base && size == 4) return _constant[channel];
      if (offset == base + 4 && size == 4) return _counter[channel];
      if (offset == base + 8 && size == 2) return _control[channel];
    }
    throw DcUnsupported('unsupported TMU read: $offset ($size bytes)');
  }

  void write(int offset, int size, int value) {
    if (offset == 0 && size == 1) {
      _output = value & 1;
      return;
    }
    if (offset == 4 && size == 1) {
      _start = value & 7;
      return;
    }
    for (var channel = 0; channel < 3; channel++) {
      final base = 8 + channel * 12;
      if (offset == base && size == 4) {
        _constant[channel] = value;
        return;
      }
      if (offset == base + 4 && size == 4) {
        _counter[channel] = value;
        return;
      }
      if (offset == base + 8 && size == 2) {
        if (value & 7 >= 5 || (channel == 2 && value & 0xc0 != 0)) {
          throw DcUnsupported(
              'TMU external clocks and capture are unimplemented');
        }
        // Hardware flags can be cleared by software, but cannot be set.
        _control[channel] =
            (value & 0x3f) | (_control[channel] & value & 0x100);
        return;
      }
    }
    throw DcUnsupported('unsupported TMU write: $offset ($size bytes)');
  }

  void tickPeripheralClocks(int clocks) {
    if (clocks < 0) throw ArgumentError.value(clocks, 'clocks');
    const divisors = [4, 16, 64, 256, 1024];
    for (var channel = 0; channel < 3; channel++) {
      if (_start & (1 << channel) == 0) continue;
      final divisor = divisors[_control[channel] & 7];
      final ticks = (_phase + clocks) ~/ divisor - _phase ~/ divisor;
      if (ticks <= _counter[channel]) {
        _counter[channel] -= ticks;
      } else {
        final remaining = ticks - _counter[channel] - 1;
        final reload = _constant[channel];
        _counter[channel] = reload - remaining % (reload + 1);
        _control[channel] |= 0x100;
      }
    }
    _phase = (_phase + clocks) % 1024;
  }
}
