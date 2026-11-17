import 'dart:typed_data';

import 'package:fnesemu_core/src/core/psp/psp.dart';
import 'package:fnesemu_core/src/core/psp/rtc.dart';
import 'package:test/test.dart';

import 'fixture.dart';

const _rtc = 'sceRtc';
const _nidResolution = 0xc41c2853;
const _nidCurrentTick = 0x3f7ad767;
const _nidCurrentClock = 0x4cfa57b0;
const _nidCurrentClockLocal = 0xe7c27d1b;
const _nidGetTick = 0x6ff40acc;
const _nidSetTick = 0x7ed29e40;
const _nidFormat2822 = 0xc663b3b9;
const _nidParseDateTime = 0xdfbc5f16;
const _nidExitGame = 0x05572a5f;

const _results = 0x09100000;
const _clock = 0x09100100;
const _clockBack = 0x09100110;
const _clockLocal = 0x09100120;
const _fixed = 0x09100130;
const _tick = 0x09100200;
const _tickFixed = 0x09100208;
const _tickParsed = 0x09100210;
const _text = 0x09100300;

List<int> _fields(RtcDateTime time) => [
      time.year,
      time.month,
      time.day,
      time.hour,
      time.minute,
      time.second,
      time.microsecond,
    ];

void _expectTime(RtcDateTime time, List<int> expected) =>
    expect(_fields(time), expected);

/// A guest that reads the clock both ways, converts a fixed date to a
/// tick, formats it and parses the text back, storing every result at
/// [_results].
Uint8List _clockProgram() {
  const imports = [
    (
      _rtc,
      [
        _nidResolution,
        _nidCurrentTick,
        _nidCurrentClock,
        _nidCurrentClockLocal,
        _nidGetTick,
        _nidSetTick,
        _nidFormat2822,
        _nidParseDateTime,
      ]
    ),
    ('LoadExecForUser', [_nidExitGame]),
  ];
  List<int> assemble(Map<String, int> stubs) {
    int stub(int nid) => stubs['$_rtc/$nid'] ?? 0;
    final exit = stubs['LoadExecForUser/$_nidExitGame'] ?? 0;
    final a = Asm(0x08800000);
    void store(int offset) => a.sw(Reg.v0, offset, Reg.s7);
    a.li(Reg.s7, _results);

    a.jal(stub(_nidResolution));
    a.nop();
    store(0);

    a.li(Reg.a0, _clock);
    a.li(Reg.a1, 0);
    a.jal(stub(_nidCurrentClock));
    a.nop();
    store(4);

    a.li(Reg.a0, _tick);
    a.jal(stub(_nidCurrentTick));
    a.nop();
    store(8);

    a.li(Reg.a0, _clockBack);
    a.li(Reg.a1, _tick);
    a.jal(stub(_nidSetTick));
    a.nop();
    store(12);

    a.li(Reg.a0, _clockLocal);
    a.jal(stub(_nidCurrentClockLocal));
    a.nop();
    store(16);

    a.li(Reg.a0, _fixed);
    a.li(Reg.a1, _tickFixed);
    a.jal(stub(_nidGetTick));
    a.nop();
    store(20);

    a.li(Reg.a0, _text);
    a.li(Reg.a1, _tickFixed);
    a.li(Reg.a2, 0);
    a.jal(stub(_nidFormat2822));
    a.nop();
    store(24);

    a.li(Reg.a0, _tickParsed);
    a.li(Reg.a1, _text);
    a.jal(stub(_nidParseDateTime));
    a.nop();
    store(28);

    a.jal(exit);
    a.nop();
    return a.finish();
  }

  final probe = buildTestElf(code: assemble(const {}), imports: imports);
  return buildTestElf(code: assemble(probe.$2.stubOf), imports: imports).$1;
}

void _runToEnd(Psp core) {
  var result = core.runFrame(286);
  var frames = 1;
  while (!result.stopped && frames < 300) {
    result = core.runFrame(286);
    frames++;
  }
  expect(result.stopped, isTrue);
}

RtcDateTime _readTime(Psp core, int at) => RtcDateTime(
      core.mem.read16(at),
      core.mem.read16(at + 2),
      core.mem.read16(at + 4),
      core.mem.read16(at + 6),
      core.mem.read16(at + 8),
      core.mem.read16(at + 10),
      core.mem.read32(at + 12),
    );

int _readTick(Psp core, int at) =>
    core.mem.read32(at) | (core.mem.read32(at + 4) << 32);

void main() {
  group('calendar', () {
    test('leap years and month lengths', () {
      expect(rtcIsLeapYear(2000), isTrue);
      expect(rtcIsLeapYear(1900), isFalse);
      expect(rtcIsLeapYear(2024), isTrue);
      expect(rtcIsLeapYear(2023), isFalse);
      expect(rtcDaysInMonth(2010, 4), 30);
      expect(rtcDaysInMonth(2024, 2), 29);
      expect(rtcDaysInMonth(2023, 2), 28);
      expect(rtcDaysInMonth(2023, 13), 0);
    });

    test('days of the week, including out of range fields', () {
      expect(rtcDayOfWeek(2010, 4, 27), 2);
      expect(rtcDayOfWeek(166970016, 1024, 0), 3);
      expect(rtcDayOfWeek(2000, 1, 0), 5);
      expect(rtcDayOfWeek(2000, 573, 0), 0);
      expect(rtcDayOfWeek(2000, 1, 2458), 6);
      expect(rtcDayOfWeek(2000, 4587, 2458), 0);
      expect(rtcDayOfWeek(2001, 1, 0), 0);
      expect(rtcDayOfWeek(2001, 573, 0), 1);
      expect(rtcDayOfWeek(2001, 1, 2458), 1);
      expect(rtcDayOfWeek(2001, 4587, 2458), 1);
      expect(rtcDayOfWeek(1, 1, 1), 1);
      expect(rtcDayOfWeek(1970, 1, 1), 4);
    });

    test('validity reports the first invalid field', () {
      RtcDateTime t(int y, int mo, int d, int h, int mi, int s, int us) =>
          RtcDateTime(y, mo, d, h, mi, s, us);
      expect(rtcCheckValid(t(2012, 9, 20, 7, 0, 0, 0)), 0);
      expect(rtcCheckValid(t(9999, 12, 31, 23, 59, 59, 999999)), 0);
      expect(rtcCheckValid(t(10000, 1, 1, 0, 0, 0, 0)), -1);
      expect(rtcCheckValid(t(0, 1, 1, 0, 0, 0, 0)), -1);
      expect(rtcCheckValid(t(2012, 13, 20, 7, 0, 0, 0)), -2);
      expect(rtcCheckValid(t(2012, 9, 31, 7, 0, 0, 0)), -3);
      expect(rtcCheckValid(t(2023, 2, 29, 7, 0, 0, 0)), -3);
      expect(rtcCheckValid(t(2012, 9, 20, 24, 0, 0, 0)), -4);
      expect(rtcCheckValid(t(2012, 9, 20, 7, 60, 0, 0)), -5);
      expect(rtcCheckValid(t(2012, 9, 20, 7, 0, 60, 0)), -6);
      expect(rtcCheckValid(t(2012, 9, 20, 7, 0, 0, 1000000)), -7);
    });
  });

  group('tick conversion', () {
    test('anchors and round trips', () {
      expect(rtcTickFromDateTime(const RtcDateTime(1, 1, 1, 0, 0, 0, 0)), 0);
      expect(rtcTickFromDateTime(const RtcDateTime(1970, 1, 1, 0, 0, 0, 0)),
          rtcUnixEpochTick);
      final fixed =
          rtcTickFromDateTime(const RtcDateTime(2012, 9, 20, 7, 12, 15, 500));
      expect((fixed - rtcUnixEpochTick) ~/ 1000000, 1348125135);
      expect(fixed % 1000000, 500);
      _expectTime(rtcDateTimeFromTick(835072), [1, 1, 1, 0, 0, 0, 835072]);
      _expectTime(
          rtcDateTimeFromTick(rtcUnixEpochTick), [1970, 1, 1, 0, 0, 0, 0]);
      _expectTime(rtcDateTimeFromTick(fixed), [2012, 9, 20, 7, 12, 15, 500]);
      _expectTime(rtcDateTimeFromTick(0), [1, 1, 1, 0, 0, 0, 0]);
    });

    test('month and year additions clamp and saturate like the hardware', () {
      int tickOf(int y, int mo, int d, [int us = 0]) =>
          rtcTickFromDateTime(RtcDateTime(y, mo, d, 0, 0, 0, us));
      _expectTime(rtcDateTimeFromTick(rtcTickAddYears(tickOf(2012, 2, 29), 1)),
          [2013, 2, 28, 0, 0, 0, 0]);
      _expectTime(rtcDateTimeFromTick(rtcTickAddYears(tickOf(2012, 2, 29), 4)),
          [2016, 2, 29, 0, 0, 0, 0]);
      _expectTime(rtcDateTimeFromTick(rtcTickAddMonths(tickOf(2012, 1, 31), 1)),
          [2012, 2, 29, 0, 0, 0, 0]);
      _expectTime(
          rtcDateTimeFromTick(rtcTickAddMonths(tickOf(1970, 1, 1, 445), 11)),
          [1970, 12, 1, 0, 0, 0, 445]);
      _expectTime(
          rtcDateTimeFromTick(rtcTickAddMonths(tickOf(1970, 1, 1, 445), -13)),
          [1968, 12, 1, 0, 0, 0, 445]);
      expect(rtcTickAddYears(tickOf(1970, 1, 1, 445), -2000), rtcSaturatedTick);
      expect(rtcTickAddYears(tickOf(9998, 1, 1), 2), rtcSaturatedTick);
      _expectTime(rtcDateTimeFromTick(rtcTickAddYears(tickOf(10, 1, 1), -9)),
          [1, 1, 1, 0, 0, 0, 0]);
    });

    test('dos time uses the raw packed fields', () {
      _expectTime(rtcDateTimeFromDos(0), [1980, 0, 0, 0, 0, 0, 0]);
      _expectTime(rtcDateTimeFromDos(1), [1980, 0, 0, 0, 0, 2, 0]);
      _expectTime(rtcDateTimeFromDos(100000), [1980, 0, 1, 16, 53, 0, 0]);
      expect(rtcDosFromDateTime(const RtcDateTime(2107, 9, 11, 24, 0, 0, 0)),
          4281057280);
      expect(rtcDosFromDateTime(const RtcDateTime(1979, 1, 1, 0, 0, 0, 0)),
          isNull);
      expect(rtcDosFromDateTime(const RtcDateTime(2108, 1, 1, 0, 0, 0, 0)),
          isNull);
      final dos =
          rtcDosFromDateTime(const RtcDateTime(2024, 3, 5, 12, 30, 44, 0))!;
      _expectTime(rtcDateTimeFromDos(dos), [2024, 3, 5, 12, 30, 44, 0]);
    });

    test('win32 file time counts 100ns from 1601', () {
      final tick =
          rtcTickFromDateTime(const RtcDateTime(2005, 12, 1, 13, 1, 0, 1));
      expect((tick - rtcWin32EpochTick) * 10, 127779156600000010);
      expect(rtcTickFromDateTime(const RtcDateTime(1601, 1, 1, 0, 0, 0, 0)),
          rtcWin32EpochTick);
    });
  });

  group('text forms', () {
    final tick =
        rtcTickFromDateTime(const RtcDateTime(2012, 1, 30, 2, 12, 15, 900));

    test('rfc 2822 and 3339 formats', () {
      expect(rtcFormatRfc2822(tick, 0), 'Mon, 30 Jan 2012 02:12:15 +0000');
      expect(rtcFormatRfc2822(tick, -60), 'Mon, 30 Jan 2012 01:12:15 -0100');
      expect(rtcFormatRfc3339(tick, 0), '2012-01-30T02:12:15.00Z');
      expect(rtcFormatRfc3339(tick, 60), '2012-01-30T03:12:15.00+01:00');
    });

    test('parse accepts the rfc forms and rejects the rest', () {
      final base =
          rtcTickFromDateTime(const RtcDateTime(2010, 9, 20, 7, 12, 15, 0));
      expect(rtcParseDateTime('2010-09-20T07:12:15.00Z'), base);
      expect(
          rtcParseDateTime('2010-09-20T07:12:15.00+01:00'), base - 3600000000);
      expect(rtcParseDateTime('2010-09-20T07:12:15Z'), base);
      expect(rtcParseDateTime('Mon, 30 Jan 2012 02:12:15 +0000'),
          rtcTickFromDateTime(const RtcDateTime(2012, 1, 30, 2, 12, 15, 0)));
      expect(rtcParseDateTime('Monday, 30 Jan 2012 02:12:15 +0000'),
          rtcTickFromDateTime(const RtcDateTime(2012, 1, 30, 2, 12, 15, 0)));
      for (final bad in [
        '2010-09-20T07:12:15',
        '2010-09-20 07:12:15Z',
        'today',
        '07:12:15',
        '2010-09-20',
        'Mon, 30 Jan 2012',
        '30 Jan 2012 02:12:15 +0000',
        'Mon,  30  Jan  2012  02:12:15  +0000',
        '',
      ]) {
        expect(rtcParseDateTime(bad), isNull, reason: bad);
      }
      expect(rtcParseRfc3339('2010-09-20T07:12:15Z'), base);
      expect(rtcParseRfc3339('Mon, 30 Jan 2012 02:12:15 +0000'), isNull);
    });
  });

  test('the guest clock reads the host time and converts consistently', () {
    final core = Psp();
    core.setRom(_clockProgram());
    core.mem.write16(_fixed, 2012);
    core.mem.write16(_fixed + 2, 9);
    core.mem.write16(_fixed + 4, 20);
    core.mem.write16(_fixed + 6, 7);
    core.mem.write16(_fixed + 8, 12);
    core.mem.write16(_fixed + 10, 15);
    core.mem.write32(_fixed + 12, 500);
    _runToEnd(core);

    int at(int offset) => core.mem.read32(_results + offset);
    for (final offset in [0, 4, 8, 12, 16, 20, 24, 28]) {
      expect(at(offset), offset == 0 ? 1000000 : 0, reason: 'result $offset');
    }

    final clock = _readTime(core, _clock);
    final hostTick =
        DateTime.now().toUtc().microsecondsSinceEpoch + rtcUnixEpochTick;
    expect((rtcTickFromDateTime(clock) - hostTick).abs(), lessThan(5000000));
    expect(rtcCheckValid(clock), 0);

    final back = _readTime(core, _clockBack);
    final tick = _readTick(core, _tick);
    expect(rtcTickFromDateTime(back), tick);
    expect((tick - hostTick).abs(), lessThan(5000000));

    final local = _readTime(core, _clockLocal);
    expect(rtcCheckValid(local), 0);
    expect(local.year, clock.year);

    final fixedTick = _readTick(core, _tickFixed);
    expect(fixedTick,
        rtcTickFromDateTime(const RtcDateTime(2012, 9, 20, 7, 12, 15, 500)));
    expect(core.mem.readString(_text, 64), 'Thu, 20 Sep 2012 07:12:15 +0000');
    expect(_readTick(core, _tickParsed), fixedTick - 500);
  });
}
