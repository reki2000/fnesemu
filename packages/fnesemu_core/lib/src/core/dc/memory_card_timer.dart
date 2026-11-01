import 'dart:typed_data';

import '../../pad_button.dart';
import '../../state.dart';
import '../../util/uint8list.dart';
import 'fault.dart';

/// FT3 calendar, setting buttons and alarm registers on the nominal master clock.
/// The memory card peripheral specification Rev. 1.00 and FT3 Rev. 0.80; no host wall-clock dependency.
class DcMemoryCardTimer {
  DcMemoryCardTimer({DateTime? initialTime})
      : _time = initialTime == null
            ? DateTime.utc(2000, 1, 1)
            : DateTime.utc(initialTime.year, initialTime.month, initialTime.day,
                initialTime.hour, initialTime.minute, initialTime.second) {
    RangeError.checkValueInInterval(_time.year, 0, 9999, 'year');
  }
  static const clocksPerSecond = 200000000;
  static const a = PadButton('A'), b = PadButton('B');
  static const _buttons = [
    (PadButton.up, 1, 2),
    (PadButton.down, 2, 1),
    (PadButton.left, 4, 8),
    (PadButton.right, 8, 4),
    (a, 16, 0),
    (b, 32, 0),
  ];
  DateTime _time;
  int _fraction = 0, _keys = 255;
  int alarmPeriod = 0, alarmDuty = 0;
  DateTime get time => _time;

  void saveState(StateWriter writer) {
    writer.section('dc.memory_card.timer');
    writer.ints([
      _time.year,
      _time.month,
      _time.day,
      _time.hour,
      _time.minute,
      _time.second,
      _fraction,
      _keys,
      alarmPeriod,
      alarmDuty
    ]);
  }

  void loadState(StateReader reader) {
    reader.section('dc.memory_card.timer');
    final v = reader.ints();
    if (v.length != 10 ||
        v.any((value) => value < 0) ||
        v[0] > 9999 ||
        v[1] < 1 ||
        v[1] > 12 ||
        v[2] < 1 ||
        v[2] > 31 ||
        v[3] > 23 ||
        v[4] > 59 ||
        v[5] > 59 ||
        v[6] >= clocksPerSecond ||
        v[7] > 255 ||
        v[8] > 255 ||
        v[9] > v[8]) {
      throw const StateMismatch('Memory card timer state');
    }
    final time = DateTime.utc(v[0], v[1], v[2], v[3], v[4], v[5]);
    if (time.month != v[1] || time.day != v[2]) {
      throw const StateMismatch('Memory card calendar date');
    }
    _time = time;
    _fraction = v[6];
    _keys = v[7];
    alarmPeriod = v[8];
    alarmDuty = v[9];
  }

  void setButton(PadButton button, bool pressed) {
    for (final (key, bit, opposite) in _buttons) {
      if (button == key) {
        _keys = pressed ? (_keys & ~bit) | opposite : _keys | bit;
      }
    }
  }

  /// Protocol reset silences alarms; the battery-backed calendar keeps running.
  void reset() {
    alarmPeriod = alarmDuty = 0;
  }

  void tickMasterClocks(int clocks) {
    if (clocks < 0) throw ArgumentError.value(clocks, 'clocks');
    final total = _fraction + clocks;
    final seconds = total ~/ clocksPerSecond;
    if (seconds != 0) {
      final next = _time.add(Duration(seconds: seconds));
      if (next.year > 9999) {
        throw const DcUnsupported('Memory card calendar year overflow');
      }
      _time = next;
    }
    _fraction = total % clocksPerSecond;
  }

  (int, List<int>) command(int code, Uint8List request) {
    const retry = (0xfc, <int>[]);
    if (code == 9) {
      if (request.length != 8) return retry;
      return (8, [0, 0, 0, 8, _keys, 0, 0, 0]);
    }
    if (code == 14) {
      if (request.length != 12 ||
          request[9] > request[8] ||
          request[10] != 0 ||
          request[11] != 0) {
        return retry;
      }
      alarmPeriod = request[8];
      alarmDuty = request[9];
      return (7, const []);
    }
    if (code != 11 && code != 12) return (0xfd, const []);
    if (request.length != (code == 11 ? 12 : 20) ||
        request[8] != 0 ||
        request[9] != 0 ||
        request[10] != 0 ||
        request[11] != 0) {
      return retry;
    }
    if (code == 11) {
      return (
        8,
        [
          0,
          0,
          0,
          8,
          _time.year & 255,
          _time.year >> 8,
          _time.month,
          _time.day,
          _time.hour,
          _time.minute,
          _time.second,
          0
        ]
      );
    }
    final year = request.getUint16LE(12),
        month = request[14],
        day = request[15];
    final hour = request[16], minute = request[17], second = request[18];
    if (year > 9999 ||
        month < 1 ||
        month > 12 ||
        day < 1 ||
        day > 31 ||
        hour > 23 ||
        minute > 59 ||
        second > 59) {
      return retry;
    }
    final next = DateTime.utc(year, month, day, hour, minute, second);
    if (next.month != month || next.day != day) return retry;
    _time = next;
    _fraction = 0;
    // TR/TW exclude weekday; writes to unavailable time fields are ignored.
    return (7, const []);
  }
}
