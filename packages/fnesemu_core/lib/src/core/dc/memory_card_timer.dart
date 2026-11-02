import 'dart:typed_data';

import '../../pad_button.dart';
import '../../state.dart';
import '../../util/uint8list.dart';
import 'fault.dart';

/// FT3 battery-backed calendar, setting buttons and alarm registers.
/// The RTC follows the host wall clock even while emulation is suspended.
/// The memory card peripheral specification Rev. 1.00 and FT3 Rev. 0.80.
class DcMemoryCardTimer {
  DcMemoryCardTimer({DateTime? initialTime, DateTime Function()? clock}) {
    this.clock = clock ?? DateTime.now;
    if (initialTime != null) {
      RangeError.checkValueInInterval(initialTime.year, 0, 9999, 'year');
      final start = DateTime.utc(initialTime.year, initialTime.month,
          initialTime.day, initialTime.hour, initialTime.minute,
          initialTime.second);
      _offsetMilliseconds = start.millisecondsSinceEpoch - _hostMilliseconds;
    }
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
  /// Replaceable host clock for deterministic tests.
  late DateTime Function() clock;
  int _offsetMilliseconds = 0, _keys = 255;
  int alarmPeriod = 0, alarmDuty = 0;

  // VMU calendar fields do not carry a timezone; use host local civil time.
  int get _hostMilliseconds {
    final now = clock();
    return DateTime.utc(now.year, now.month, now.day, now.hour, now.minute,
            now.second, now.millisecond)
        .millisecondsSinceEpoch;
  }

  DateTime get time => DateTime.fromMillisecondsSinceEpoch(
      _hostMilliseconds + _offsetMilliseconds, isUtc: true);

  void saveState(StateWriter writer) {
    writer.section('dc.memory_card.timer');
    writer.ints([_offsetMilliseconds, _keys, alarmPeriod, alarmDuty]);
  }

  void loadState(StateReader reader) {
    reader.section('dc.memory_card.timer');
    final v = reader.ints();
    if (v.length != 4 ||
        v[1] < 0 ||
        v[1] > 255 ||
        v[2] < 0 ||
        v[2] > 255 ||
        v[3] < 0 ||
        v[3] > v[2]) {
      throw const StateMismatch('Memory card timer state');
    }
    final restored = DateTime.fromMillisecondsSinceEpoch(
        _hostMilliseconds + v[0], isUtc: true);
    if (restored.year < 0 || restored.year > 9999) {
      throw const StateMismatch('Memory card calendar date');
    }
    _offsetMilliseconds = v[0];
    _keys = v[1];
    alarmPeriod = v[2];
    alarmDuty = v[3];
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
    // The independent battery-backed RTC is not driven by emulated clocks.
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
      final current = time; // Capture one instant for the whole reply.
      if (current.year < 0 || current.year > 9999) {
        throw const DcUnsupported('Memory card calendar year overflow');
      }
      return (
        8,
        [
          0,
          0,
          0,
          8,
          current.year & 255,
          current.year >> 8,
          current.month,
          current.day,
          current.hour,
          current.minute,
          current.second,
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
    _offsetMilliseconds = next.millisecondsSinceEpoch - _hostMilliseconds;
    // TR/TW exclude weekday; writes to unavailable time fields are ignored.
    return (7, const []);
  }
}
