// Calendar arithmetic for the real-time clock services.
//
// The hardware tick is a count of microseconds since 0001-01-01 UTC. The day formulas are linear in the month and day fields, so out of range fields convert the same way the hardware's arithmetic converts them instead of being rejected; whether a date is valid is a separate query (rtcCheckValid).

/// A broken-down date and time, mirroring the guest's ScePspDateTime.
class RtcDateTime {
  final int year;
  final int month;
  final int day;
  final int hour;
  final int minute;
  final int second;
  final int microsecond;

  const RtcDateTime(this.year, this.month, this.day, this.hour, this.minute,
      this.second, this.microsecond);

  @override
  String toString() => '$year-$month-$day $hour:$minute:$second.$microsecond';
}

/// The tick of the unix epoch, 1970-01-01 UTC.
const int rtcUnixEpochTick = 62135596800000000;

/// The tick of the Win32 file time epoch, 1601-01-01 UTC.
const int rtcWin32EpochTick = 50491123200000000;

/// The tick the month and year additions saturate to when the result leaves the supported year range, matching the hardware's clamp artifact.
const int rtcSaturatedTick = 4919;

const int _microsPerDay = 86400000000;

/// Floor division for a positive divisor, unlike Dart's truncating ~/.
int _floorDiv(int a, int b) => (a - (a % b)) ~/ b;

/// Whether [year] is a leap year under the Gregorian rule.
bool rtcIsLeapYear(int year) =>
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);

const List<int> _monthLengths = <int>[
  31,
  28,
  31,
  30,
  31,
  30,
  31,
  31,
  30,
  31,
  30,
  31
];

/// The number of days in [month] of [year], or zero for a month outside 1..12.
int rtcDaysInMonth(int year, int month) {
  if (month < 1 || month > 12) return 0;
  if (month == 2 && rtcIsLeapYear(year)) return 29;
  return _monthLengths[month - 1];
}

/// Days from 1970-01-01 to the given date, with the month counted from March and left unclamped so out of range months and days extend linearly.
int _daysFromCivil(int year, int month, int day) {
  final y = year - (month <= 2 ? 1 : 0);
  final era = _floorDiv(y, 400);
  final yoe = y - era * 400;
  final mp = month >= 3 ? month - 3 : month + 9;
  final doy = _floorDiv(153 * mp + 2, 5) + day - 1;
  final doe = yoe * 365 + yoe ~/ 4 - yoe ~/ 100 + doy;
  return era * 146097 + doe - 719468;
}

/// The date [days] after 1970-01-01, as a (year, month, day) record with every field in range.
(int, int, int) _civilFromDays(int days) {
  final z = days + 719468;
  final era = _floorDiv(z, 146097);
  final doe = z - era * 146097;
  final yoe = (doe - doe ~/ 1460 + doe ~/ 36524 - doe ~/ 146096) ~/ 365;
  final doy = doe - (365 * yoe + yoe ~/ 4 - yoe ~/ 100);
  final mp = (5 * doy + 2) ~/ 153;
  final day = doy - (153 * mp + 2) ~/ 5 + 1;
  final month = mp + (mp < 10 ? 3 : -9);
  return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, day);
}

/// The day of the week for a date, 0 for Sunday through 6 for Saturday.
int rtcDayOfWeek(int year, int month, int day) =>
    (_daysFromCivil(year, month, day) + 4) % 7;

/// Validates a date the way the hardware does, returning zero when valid or a negative code for the first invalid field: -1 year, -2 month, -3 day, -4 hour, -5 minute, -6 second, -7 microsecond.
int rtcCheckValid(RtcDateTime time) {
  if (time.year < 1 || time.year > 9999) return -1;
  if (time.month < 1 || time.month > 12) return -2;
  if (time.day < 1 || time.day > rtcDaysInMonth(time.year, time.month)) {
    return -3;
  }
  if (time.hour < 0 || time.hour > 23) return -4;
  if (time.minute < 0 || time.minute > 59) return -5;
  if (time.second < 0 || time.second > 59) return -6;
  if (time.microsecond < 0 || time.microsecond > 999999) return -7;
  return 0;
}

/// The tick of a broken-down time, with every field used as given.
int rtcTickFromDateTime(RtcDateTime time) {
  final days = _daysFromCivil(time.year, time.month, time.day) + 719162;
  final micros = ((time.hour * 60 + time.minute) * 60 + time.second) * 1000000 +
      time.microsecond;
  return days * _microsPerDay + micros;
}

/// The broken-down time of a tick, with every field in range.
RtcDateTime rtcDateTimeFromTick(int tick) {
  final days = _floorDiv(tick, _microsPerDay);
  var rest = tick - days * _microsPerDay;
  final (year, month, day) = _civilFromDays(days - 719162);
  final hour = rest ~/ 3600000000;
  rest -= hour * 3600000000;
  final minute = rest ~/ 60000000;
  rest -= minute * 60000000;
  final second = rest ~/ 1000000;
  return RtcDateTime(
      year, month, day, hour, minute, second, rest - second * 1000000);
}

/// Adds calendar months to a tick, clamping the day to the target month and saturating outside the supported year range.
int rtcTickAddMonths(int tick, int months) {
  final time = rtcDateTimeFromTick(tick);
  final total = time.year * 12 + (time.month - 1) + months;
  final year = _floorDiv(total, 12);
  if (year < 1 || year > 9999) return rtcSaturatedTick;
  final month = total - year * 12 + 1;
  final days = rtcDaysInMonth(year, month);
  final day = time.day > days ? days : time.day;
  return rtcTickFromDateTime(RtcDateTime(
      year, month, day, time.hour, time.minute, time.second, time.microsecond));
}

/// Adds calendar years to a tick, with the same clamping as [rtcTickAddMonths].
int rtcTickAddYears(int tick, int years) => rtcTickAddMonths(tick, years * 12);

/// The broken-down time of a packed DOS date and time, with every field used as stored.
RtcDateTime rtcDateTimeFromDos(int dos) => RtcDateTime(
      1980 + ((dos >> 25) & 0x7f),
      (dos >> 21) & 0xf,
      (dos >> 16) & 0x1f,
      (dos >> 11) & 0x1f,
      (dos >> 5) & 0x3f,
      (dos & 0x1f) * 2,
      0,
    );

/// The packed DOS date and time of a broken-down time, or null when the year is outside the DOS range of 1980..2107; the other fields are packed as stored, each masked to its field width.
int? rtcDosFromDateTime(RtcDateTime time) {
  if (time.year < 1980 || time.year > 2107) return null;
  return ((time.year - 1980) << 25) |
      ((time.month & 0xf) << 21) |
      ((time.day & 0x1f) << 16) |
      ((time.hour & 0x1f) << 11) |
      ((time.minute & 0x3f) << 5) |
      ((time.second >> 1) & 0x1f);
}

const List<String> _weekdayShort = <String>[
  'Sun',
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat'
];
const List<String> _monthShort = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec'
];

String _two(int value) => value.toString().padLeft(2, '0');
String _four(int value) => value.toString().padLeft(4, '0');

String _zoneOffset(int tzMinutes, String separator) {
  final sign = tzMinutes < 0 ? '-' : '+';
  final abs = tzMinutes.abs();
  return '$sign${_two(abs ~/ 60)}$separator${_two(abs % 60)}';
}

/// Formats a UTC tick as an RFC 2822 date in the zone [tzMinutes] from UTC, for example `Mon, 30 Jan 2012 02:12:15 +0000`.
String rtcFormatRfc2822(int tick, int tzMinutes) {
  final time = rtcDateTimeFromTick(tick + tzMinutes * 60000000);
  final weekday = _weekdayShort[rtcDayOfWeek(time.year, time.month, time.day)];
  return '$weekday, ${_two(time.day)} ${_monthShort[time.month - 1]} '
      '${_four(time.year)} ${_two(time.hour)}:${_two(time.minute)}:'
      '${_two(time.second)} ${_zoneOffset(tzMinutes, '')}';
}

/// Formats a UTC tick as an RFC 3339 date in the zone [tzMinutes] from UTC, for example `2012-01-30T02:12:15.00Z`, with the fraction in hundredths.
String rtcFormatRfc3339(int tick, int tzMinutes) {
  final time = rtcDateTimeFromTick(tick + tzMinutes * 60000000);
  final zone = tzMinutes == 0 ? 'Z' : _zoneOffset(tzMinutes, ':');
  return '${_four(time.year)}-${_two(time.month)}-${_two(time.day)}T'
      '${_two(time.hour)}:${_two(time.minute)}:${_two(time.second)}.'
      '${_two(time.microsecond ~/ 10000)}$zone';
}

final RegExp _rfc3339Pattern = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d+)?(Z|[+-]\d{2}:\d{2})$');
final RegExp _rfc2822Pattern = RegExp(
    r'^(Sun|Mon|Tue|Wed|Thu|Fri|Sat|Sunday|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday), '
    r'(\d{1,2}) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) (\d{4}) '
    r'(\d{2}):(\d{2}):(\d{2}) ([+-]\d{4})$');

bool _fieldsInRange(int month, int day, int hour, int minute, int second) =>
    month >= 1 &&
    month <= 12 &&
    day >= 1 &&
    day <= 31 &&
    hour <= 23 &&
    minute <= 59 &&
    second <= 59;

/// Parses an RFC 3339 date into a UTC tick, or returns null when the text is not exactly that form.
int? rtcParseRfc3339(String text) {
  final match = _rfc3339Pattern.firstMatch(text);
  if (match == null) return null;
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  final hour = int.parse(match[4]!);
  final minute = int.parse(match[5]!);
  final second = int.parse(match[6]!);
  if (!_fieldsInRange(month, day, hour, minute, second)) return null;
  var microsecond = 0;
  final fraction = match[7];
  if (fraction != null) {
    final digits = '${fraction.substring(1)}000000'.substring(0, 6);
    microsecond = int.parse(digits);
  }
  var tzMinutes = 0;
  final zone = match[8]!;
  if (zone != 'Z') {
    final sign = zone.startsWith('-') ? -1 : 1;
    tzMinutes = sign *
        (int.parse(zone.substring(1, 3)) * 60 +
            int.parse(zone.substring(4, 6)));
  }
  final local = rtcTickFromDateTime(
      RtcDateTime(year, month, day, hour, minute, second, microsecond));
  return local - tzMinutes * 60000000;
}

/// Parses an RFC 3339 or RFC 2822 date into a UTC tick, or returns null when the text matches neither form.
int? rtcParseDateTime(String text) {
  final tick = rtcParseRfc3339(text);
  if (tick != null) return tick;
  final match = _rfc2822Pattern.firstMatch(text);
  if (match == null) return null;
  final day = int.parse(match[2]!);
  final month = _monthShort.indexOf(match[3]!) + 1;
  final year = int.parse(match[4]!);
  final hour = int.parse(match[5]!);
  final minute = int.parse(match[6]!);
  final second = int.parse(match[7]!);
  if (!_fieldsInRange(month, day, hour, minute, second)) return null;
  final zone = match[8]!;
  final sign = zone.startsWith('-') ? -1 : 1;
  final tzMinutes = sign *
      (int.parse(zone.substring(1, 3)) * 60 + int.parse(zone.substring(3, 5)));
  final local = rtcTickFromDateTime(
      RtcDateTime(year, month, day, hour, minute, second, 0));
  return local - tzMinutes * 60000000;
}
