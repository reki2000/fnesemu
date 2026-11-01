import 'dart:typed_data';

import '../../state.dart';

import 'fault.dart';

/// SH7750 bus configuration and functional refresh counters (hardware manual 13.2).
/// External wait-state waveforms and SDRAM command timing are pending.
class DcBsc {
  DcBsc({this.area0Width = 0}) {
    if (area0Width < 0 || area0Width > 3) throw ArgumentError.value(area0Width);
    reset();
  }
  final int area0Width;
  final _values = Uint32List(11);
  int _phase = 0;
  final mode = Uint16List(2);
  final precharges = Uint32List(2);
  static const _offsets = [0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40];
  static const _sizes = [4, 2, 4, 4, 4, 4, 2, 2, 2, 2, 2];
  static const _masks = [
    0x033efffd,
    0x3ffd,
    0x77777777,
    0xfffeefff,
    0x07777777,
    0xf8bbffff,
    0xffff,
    0xff,
    0xff,
    0xff,
    0x3ff
  ];
  static const _divisors = [0, 4, 16, 64, 256, 1024, 2048, 4096];

  static int? offset(int address) {
    if (address >= 0xc0000000 && address < 0xe0000000) return null;
    final physical = address & 0x1fffffff;
    return physical >= 0x1f800000 && physical <= 0x1f800028
        ? physical - 0x1f800000
        : null;
  }

  static int? modeArea(int address) {
    final physical = address & 0x1fffffff;
    if ((address < 0xc0000000 || address >= 0xff000000) &&
        physical >= 0x1f900000 &&
        physical < 0x1f902000) {
      return 0;
    }
    if ((address < 0xc0000000 || address >= 0xff000000) &&
        physical >= 0x1f940000 &&
        physical < 0x1f942000) {
      return 1;
    }
    return null;
  }

  void reset({bool powerOn = true}) {
    if (!powerOn) return;
    _values.setAll(0, [
      0x80000000,
      (area0Width << 14) | 0x3ffc,
      0x77777777,
      0xfffeefff,
      0x07777777,
      0,
      0,
      0,
      0,
      0,
      0
    ]);
    _phase = 0;
    mode.fillRange(0, 2, 0);
    precharges.fillRange(0, 2, 0);
  }

  void saveState(StateWriter writer) {
    writer.section('dc.sh4.bsc');
    writer.int32(area0Width);
    writer.ints(_values);
    writer.ints(mode);
    writer.ints(precharges);
    writer.int32(_phase);
  }

  void loadState(StateReader reader) {
    reader.section('dc.sh4.bsc');
    final width = reader.int32(), values = reader.ints();
    final modes = reader.ints(), counts = reader.ints();
    final phase = reader.int32();
    if (width != area0Width ||
        values.length != 11 ||
        modes.length != 2 ||
        counts.length != 2 ||
        modes.any((value) => value < 0 || value > 0xffff) ||
        counts.any((value) => value < 0 || value > 0xffffffff)) {
      throw const StateMismatch('SH4 bus control layout');
    }
    for (var i = 0; i < values.length; i++) {
      final mask = _masks[i] |
          (i == 0
              ? 0x80000000
              : i == 1
                  ? 0xc000
                  : 0);
      if (values[i] < 0 || values[i] & ~mask != 0) {
        throw const StateMismatch('SH4 bus control register');
      }
    }
    final divisor = _divisors[(values[7] >> 3) & 7];
    if (values[0] & 0x80000000 == 0 ||
        values[1] >> 14 != area0Width ||
        phase < 0 ||
        (divisor == 0 ? phase != 0 : phase >= divisor)) {
      throw const StateMismatch('SH4 bus control phase or straps');
    }
    _values.setAll(0, values);
    mode.setAll(0, modes);
    precharges.setAll(0, counts);
    _phase = phase;
  }

  int _index(int offset, int size) {
    final index = _offsets.indexOf(offset);
    if (index < 0 || size != _sizes[index]) {
      throw const DcUnsupported('BSC register access width or address');
    }
    return index;
  }

  /// Level requests remain asserted until software clears their status flags.
  int get interruptEvent {
    final status = _values[7];
    if (status & 0xc0 == 0xc0) return 0x580;
    if (status & 6 == 6) return 0x5a0;
    return 0;
  }

  int read(int offset, int size) => _values[_index(offset, size)];
  void write(int offset, int size, int value) {
    final index = _index(offset, size);
    if (index >= 7) {
      final keyMask = index == 10 ? 0xfc00 : 0xff00;
      if (value & keyMask != 0xa400 + (index == 10 ? 0 : 0x100)) return;
      if (index == 7) {
        final previous = _values[index];
        _values[index] = (value & 0x7b) | (previous & value & 0x84);
        if ((previous ^ value) & 0x38 != 0) _phase = 0;
        return;
      }
    }
    _values[index] = index == 0
        ? 0x80000000 | (value & _masks[index])
        : index == 1
            ? (area0Width << 14) | (value & _masks[index])
            : value & _masks[index];
  }

  void writeMode(int area, int address, int size) {
    if (size != 1) throw const DcUnsupported('SDRAM mode requires byte writes');
    final width = (_values[1] >> (area == 0 ? 4 : 6)) & 3;
    if (width != 0 && width != 3) {
      throw const DcUnsupported('SDRAM mode requires a 32-bit or 64-bit bus');
    }
    if (_values[5] & 0x40000000 == 0) {
      precharges[area]++;
      return;
    }
    // SH-4 A2 (32-bit bus) or A3 (64-bit bus) drives SDRAM A0.
    final shift = width == 0 ? 3 : 2;
    if (address & 0x1fff > (0x3ff << shift)) {
      throw const DcUnsupported('SDRAM mode address exceeds ten mode bits');
    }
    mode[area] = (address & 0x1fff) >> shift;
  }

  void tickBusClocks(int clocks) {
    if (clocks < 0) throw ArgumentError.value(clocks, 'clocks');
    final divisor = _divisors[(_values[7] >> 3) & 7];
    if (divisor == 0) return;
    final elapsed = _phase + clocks, ticks = elapsed ~/ divisor;
    _phase = elapsed % divisor;
    if (ticks == 0) return;
    var first = (_values[9] - _values[8]) & 255;
    if (first == 0) first = 256;
    if (ticks < first) {
      _values[8] = (_values[8] + ticks) & 255;
      return;
    }
    final period = _values[9] == 0 ? 256 : _values[9];
    final matches = 1 + (ticks - first) ~/ period;
    _values[8] = (ticks - first) % period;
    _values[7] |= 0x80;
    final limit = _values[7] & 1 != 0 ? 512 : 1024;
    final count = _values[10] + matches;
    if (count >= limit) _values[7] |= 4;
    _values[10] = count % limit;
  }
}
