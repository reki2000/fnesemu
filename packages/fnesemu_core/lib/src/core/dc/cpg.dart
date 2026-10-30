import '../../state.dart';

import 'fault.dart';

/// SH7750 mode-5 clocks, watchdog and clock-stabilization state.
/// Master ticks use the board's nominal 200 MHz PLL output as a fixed timebase.
class DcCpg {
  static const resetFrequency = 0x0e0a;
  static const _divisors = [1, 2, 3, 4, 6, 8];
  static const _settings = [
    0x008,
    0x00a,
    0x00c,
    0x011,
    0x013,
    0x01a,
    0x01c,
    0x023,
    0x02c,
    0x05a,
    0x05c,
    0x063,
    0x06c,
    0x0a3,
    0x0ec
  ];
  int _frequency = resetFrequency, _counter = 0, _watchdog = 0;
  int standby = 0, standby2 = 0;
  int _busPhase = 0, _peripheralPhase = 0, _watchdogPhase = 0;
  int _stabilizations = 0, _preset = 0;
  bool? _resetRequest;
  bool deepSleeping = false;

  int get _sourcePeriod => _frequency & 0x400 != 0 ? 1 : 6;
  int get cpuPeriod => _sourcePeriod * _divisors[(_frequency >> 6) & 7];
  int get busPeriod => _sourcePeriod * _divisors[(_frequency >> 3) & 7];
  int get peripheralPeriod => _sourcePeriod * _divisors[(_frequency & 7) + 1];
  int get watchdogPeriod => _sourcePeriod * (32 << (_watchdog & 7));
  bool get stabilizing => _stabilizations != 0;
  bool get interruptPending => _watchdog & 0x48 == 8;
  int get clocksToBusEdge =>
      stabilizing ? stabilizationClocks : busPeriod - _busPhase;
  int get stabilizationClocks => !stabilizing
      ? 0
      : (256 - _counter) * watchdogPeriod -
          _watchdogPhase +
          (_stabilizations - 1) * (256 - _preset) * watchdogPeriod;

  void reset({bool powerOn = true}) {
    deepSleeping = false;
    _resetRequest = null;
    if (!powerOn) return;
    _frequency = resetFrequency;
    _counter = _watchdog = standby = standby2 = 0;
    _busPhase = _peripheralPhase = _watchdogPhase = 0;
    _stabilizations = _preset = 0;
  }

  void saveState(StateWriter writer) {
    writer.section('dc.sh4.cpg');
    writer.ints([
      _frequency,
      _counter,
      _watchdog,
      standby,
      standby2,
      _busPhase,
      _peripheralPhase,
      _watchdogPhase,
      _stabilizations,
      _preset,
      _resetRequest == null
          ? -1
          : _resetRequest!
              ? 1
              : 0
    ]);
    writer.boolean(deepSleeping);
  }

  /// Restore clock fractions and reset requests without register-write actions.
  void loadState(StateReader reader) {
    reader.section('dc.sh4.cpg');
    final values = reader.ints();
    final deepSleep = reader.boolean();
    if (values.length != 11 ||
        values.take(10).any((value) => value < 0) ||
        values[0] > 0xfff ||
        !_settings.contains(values[0] & 0x1ff) ||
        [1, 2, 3, 9].any((index) => values[index] > 255) ||
        values[4] & ~0x80 != 0 ||
        values[8] > 2 ||
        values[10] < -1 ||
        values[10] > 1 ||
        (deepSleep && (values[3] & 0x80 != 0 || values[4] & 0x80 == 0))) {
      throw const StateMismatch('SH4 clock state');
    }
    final source = values[0] & 0x400 != 0 ? 1 : 6;
    final bus = source * _divisors[(values[0] >> 3) & 7];
    final peripheral = source * _divisors[(values[0] & 7) + 1];
    final watchdog = source * (32 << (values[2] & 7));
    if (values[5] >= bus || values[6] >= peripheral || values[7] >= watchdog) {
      throw const StateMismatch('SH4 clock phase');
    }
    _frequency = values[0];
    _counter = values[1];
    _watchdog = values[2];
    standby = values[3];
    standby2 = values[4];
    _busPhase = values[5];
    _peripheralPhase = values[6];
    _watchdogPhase = values[7];
    _stabilizations = values[8];
    _preset = values[9];
    _resetRequest = values[10] == -1 ? null : values[10] == 1;
    deepSleeping = deepSleep;
  }

  bool? takeReset() {
    final request = _resetRequest;
    _resetRequest = null;
    if (request != null) {
      // STBCR/STBCR2 reset on either watchdog reset; FRQCR/WTCSR are held.
      standby = standby2 = 0;
    }
    return request;
  }

  int read(int offset, int size) {
    if (offset == 0 && size == 2) return _frequency;
    if (size == 1) {
      return switch (offset) {
        4 => standby,
        8 => _counter,
        12 => _watchdog,
        16 => standby2,
        _ => throw DcUnsupported('unsupported CPG register: $offset'),
      };
    }
    throw DcUnsupported('unsupported CPG read width: $offset/$size');
  }

  void write(int offset, int size, int value) {
    if (offset == 0 && size == 2) {
      value &= 0xfff;
      if (!_settings.contains(value & 0x1ff)) {
        throw DcUnsupported('prohibited FRQCR division ratios');
      }
      final changed = value ^ _frequency;
      final pll1Changed = changed & 0x400 != 0;
      var waits = 0;
      if (pll1Changed) {
        if (value & 0x400 != 0) waits++;
        if (value & 0x200 != 0) waits++;
      } else if ((changed & 0x200 != 0 || changed & 0x38 != 0) &&
          value & 0x200 != 0) {
        waits = 1;
      }
      if (waits != 0 && _watchdog & 0x80 != 0) {
        throw DcUnsupported('clock stabilization requires a stopped watchdog');
      }
      _frequency = value;
      _busPhase %= busPeriod;
      _peripheralPhase %= peripheralPeriod;
      _watchdogPhase %= watchdogPeriod;
      if (waits != 0) {
        _stabilizations = waits;
        _preset = _counter;
        _watchdogPhase = 0;
      }
      return;
    }
    if (size == 1 && offset == 4) {
      standby = value & 255;
      return;
    }
    if (size == 1 && offset == 16) {
      standby2 = value & 0x80;
      return;
    }
    if (size == 2 && offset == 8) {
      if ((value >> 8) & 255 == 0x5a) {
        _counter = value & 255;
        _watchdogPhase = 0;
      }
      return;
    }
    if (size == 2 && offset == 12) {
      if ((value >> 8) & 255 == 0xa5) {
        _watchdog = value & 255;
        _watchdogPhase %= watchdogPeriod;
      }
      return;
    }
    throw DcUnsupported('unsupported CPG write: $offset/$size');
  }

  /// Returns peripheral and bus clock edges while advancing fixed master time.
  (int, int) advance(int clocks) {
    if (clocks < 0) throw ArgumentError.value(clocks, 'clocks');
    while (stabilizing && clocks > 0) {
      final untilOverflow = (256 - _counter) * watchdogPeriod - _watchdogPhase;
      if (clocks < untilOverflow) {
        final total = _watchdogPhase + clocks;
        _counter += total ~/ watchdogPeriod;
        _watchdogPhase = total % watchdogPeriod;
        return (0, 0);
      }
      clocks -= untilOverflow;
      _watchdogPhase = 0;
      _stabilizations--;
      _counter = stabilizing ? _preset : 0;
    }
    // Short advances stay below one period; skip the variable divisions then.
    var peripheral = 0, bus = 0, ticks = 0;
    final peripheralTotal = _peripheralPhase + clocks,
        peripheralLength = peripheralPeriod;
    if (peripheralTotal < peripheralLength) {
      _peripheralPhase = peripheralTotal;
    } else {
      peripheral = peripheralTotal ~/ peripheralLength;
      _peripheralPhase = peripheralTotal % peripheralLength;
    }
    final busTotal = _busPhase + clocks, busLength = busPeriod;
    if (busTotal < busLength) {
      _busPhase = busTotal;
    } else {
      bus = busTotal ~/ busLength;
      _busPhase = busTotal % busLength;
    }
    final watchdogTotal = _watchdogPhase + clocks,
        watchdogLength = watchdogPeriod;
    if (watchdogTotal < watchdogLength) {
      _watchdogPhase = watchdogTotal;
    } else {
      ticks = watchdogTotal ~/ watchdogLength;
      _watchdogPhase = watchdogTotal % watchdogLength;
    }
    if (_watchdog & 0x80 != 0) {
      final next = _counter + ticks;
      _counter = next & 255;
      if (next >= 256) {
        if (_watchdog & 0x40 != 0) {
          _watchdog |= 0x10;
          _resetRequest ??= _watchdog & 0x20 != 0;
        } else {
          _watchdog |= 8;
        }
      }
    }
    return (peripheral, bus);
  }
}
