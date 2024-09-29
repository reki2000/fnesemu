// Dart imports:
import 'dart:developer';
import 'dart:typed_data';

import '../../../util.dart';

// Project imports

mixin _Wave {
  bool _enabled = false;
  int _freq = 0;

  void reset() {} // to be overridden

  void setLowFreq(int val) {
    _freq = _freq.withLowByte(val);
  }

  void setHighFreq(int val) {
    _freq = _freq.withHighByte(val & 0x07);
    _enabled = bit7(val);

    if (!_enabled) {
      reset();
    }
  }
}

class _PulseWave with _Wave {
  int duty = 0;
  int volume = 0;

  int _timer = 0;
  int _dutyCycle = 15;

  @override
  void reset() {
    _dutyCycle = 15;
  }

  Int8List synth(int cycles) {
    final buf = Int8List(cycles);

    if (!_enabled) {
      return buf;
    }

    for (int i = 0; i < buf.length; i++) {
      buf[i] = _dutyCycle <= duty ? volume : 0;

      if (_timer <= 0) {
        _timer = _freq + 1;
        _dutyCycle = (_dutyCycle - 1) & 0x0f;
      }

      _timer--;
    }

    return buf;
  }
}

class _SawToothWave with _Wave {
  int accum = 0;

  int _timer = 0;
  int _count = 0;
  int _accumlator = 0;

  @override
  void reset() {
    _count = 0;
    _accumlator = 0;
  }

  Int8List synth(int cycles) {
    final buf = Int8List(cycles);

    if (!_enabled) {
      return buf;
    }

    for (int i = 0; i < buf.length; i++) {
      if (_timer <= 0) {
        _timer = _freq + 1;
        _count++;
        if (_count == 14) {
          _count = 0;
        }
        if ((_count & 0x01) == 0) {
          accum = (_accumlator + accum) & 0xff;
        }
      }
      buf[i] = _accumlator >> 3;
      _timer--;
    }
    return buf;
  }
}

/// Emulates VRC6 APU
class Vrc6Apu {
  void reset() {
    cycle = 0;
  }

  int cycle = 0;

  final pulse0 = _PulseWave();
  final pulse1 = _PulseWave();
  final saw = _SawToothWave();

  void write(int reg, int val) {
    switch (reg) {
      // pulse wave 0
      case 0x9000:
        pulse0.duty = bit7(val) ? 15 : ((val >> 4) & 0x07);
        pulse0.volume = val & 0x0f;
        return;

      case 0x9001:
        pulse0.setLowFreq(val);
        return;

      case 0x9002:
        pulse0.setHighFreq(val);
        return;

      // pulse wave 1
      case 0xa000:
        pulse1.duty = bit7(val) ? 15 : ((val >> 4) & 0x07);
        pulse1.volume = val & 0x0f;
        return;

      case 0xa001:
        pulse1.setLowFreq(val);
        return;

      case 0xa002:
        pulse1.setHighFreq(val);
        return;

      // triangle wave
      case 0xb000:
        saw.accum = val & 0x3f;
        return;

      case 0xb001:
        saw.setLowFreq(val);
        return;

      case 0xb002:
        saw.setHighFreq(val);
        return;

      default:
        log("Unsupported apu write at 0x${hex16(reg)}");
        return;
    }
  }

  /// Generates APU 1Frame output and set it to the apu output buffer
  Float32List exec(int cycles) {
    final buffer = Float32List(cycles);

    final p0 = pulse0.synth(cycles);
    final p1 = pulse1.synth(cycles);
    final s = saw.synth(cycles);

    for (int i = 0; i < cycles; i++) {
      buffer[i] = (p0[i] + p1[i] + s[i]) / 45 * 2 - 1.0;
    }

    return buffer;
  }

  String dump() {
    return "p0:${pulse0.duty} ${pulse0.volume} ${pulse0._freq} p1:${pulse1.duty} ${pulse1.volume} ${pulse1._freq} s:${saw.accum} ${saw._freq}";
  }
}
