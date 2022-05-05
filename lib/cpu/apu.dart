// Dart imports:
import 'dart:developer';
import 'dart:typed_data';

// Project imports:
import 'package:fnesemu/cpu/util.dart';

import 'bus.dart';

class _EnvelopeUnit {
  int volume = 0;

  int _period = 0;
  int _counter = 0;
  bool _loop = false;
  bool _disabled = false;

  void prepare({required bool disabled, required bool loop, required int n}) {
    _disabled = disabled;
    if (_disabled) {
      volume = n;
    } else {
      _period = n + 1;
      _loop = loop;
      keyOn();
    }
  }

  void keyOn() {
    if (!_disabled) {
      volume = 15;
      _counter = _period;
    }
  }

  void count() {
    if (_disabled) {
      return;
    }

    if (_counter > 0) {
      _counter--;
    } else {
      _counter = _period;

      if (volume == 0 && _loop) {
        volume = 15;
      } else if (volume > 0) {
        volume--;
      }
    }
  }
}

mixin _LengthCounter {
  int length = 0;
  bool halt = false;
  int lengthCounter = 0;

  bool enabled = false;

  static const lengthTable = [
    10, 254, 20, 2, 40, 4, 80, 6, 160, 8, 60, 10, 14, 12, 26, 14, //
    12, 16, 24, 18, 48, 20, 96, 22, 192, 24, 72, 26, 16, 28, 32, 30
  ];

  void countLength() {
    if (lengthCounter > 0 && !halt) lengthCounter--;
  }

  void setLength(int l) {
    length = lengthTable[l];
    lengthCounter = length;
  }
}

class _SweepUnit {
  int freq = 0;
  bool enabled = false;
  bool negate = false;
  int period = 0;
  int shift = 0;

  int _counter = 0;
  final int _adjust;

  _SweepUnit(
    this._adjust,
  );

  void sweep() {
    if (!enabled || shift == 0) {
      return;
    }

    if (_counter > 0) {
      if (negate) {
        freq -= (freq >> shift);
        freq -= _adjust;
      } else {
        freq += (freq >> shift);
      }
      if (freq > 0x7ff) {
        freq = 0x7ff;
      } else if (freq < 0) {
        freq = 0;
      }
      _counter--;
    }
    return;
  }

  void keyOn() {
    _counter = period;
  }
}

class _PulseWave with _LengthCounter {
  final envelope = _EnvelopeUnit();
  final _SweepUnit sweep;

  _PulseWave(channelNo) : sweep = _SweepUnit(channelNo == 0 ? 1 : 0);

  int dutyType = 0;

  int _timer = 0;
  int _index = 0;

  static const _waveTable = [
    [0, 1, 0, 0, 0, 0, 0, 0], // dutyType:0
    [0, 1, 1, 0, 0, 0, 0, 0], // dutyType:1
    [0, 1, 1, 1, 1, 0, 0, 0], // dutyType:2
    [1, 0, 0, 1, 1, 1, 1, 1], // dutyType:3
  ];

  void noteOn() {
    _index = 0;
    _timer = sweep.freq + 1;
    sweep.keyOn();
    envelope.keyOn();
  }

  Int8List synth(int cycles) {
    final buf = Int8List(cycles);

    if (!enabled ||
        lengthCounter == 0 ||
        sweep.freq == 0x7ff ||
        sweep.freq <= 8) {
      buf.fillRange(0, buf.length, 0);
      return Int8List(cycles);
    }

    for (int i = 0; i < buf.length; i++) {
      if (_timer == 0) {
        _timer = sweep.freq + 1;
        _index = (_index + 1) & 0x07;
      }
      buf[i] = _waveTable[dutyType][_index] == 1 ? envelope.volume : 0;
      _timer--;
    }
    return buf;
  }
}

class TriangleWave with _LengthCounter {
  int freq = 0;
  int _counter = 0;
  int _timer = 0;
  int _index = 0;
  static final table = List.generate(16, (index) => 15 - index)
    ..addAll(List.generate(16, (index) => index));

  void prepare() {
    _timer = freq + 1;
    _counter = _timer;
    _index = 0;
  }

  Int8List synth(int cycles) {
    final buf = Int8List(cycles);

    if (!enabled || lengthCounter == 0 || freq == 0x7ff || freq <= 8) {
      buf.fillRange(0, buf.length, 0);
      return buf;
    }

    for (int i = 0; i < buf.length; i++) {
      if (_counter <= 0) {
        _counter = _timer;
        _index++;
        _index &= 0x1f;
      }
      buf[i] = table[_index];
      _counter--;
      _counter--;
    }
    return buf;
  }
}

class NoiseWave with _LengthCounter {
  final envelope = _EnvelopeUnit();

  int freq = 0;
  int volume = 0;
  int counter = 0;
  int timer = 0;
  int reg = 1;
  bool short = false;
  static const _table = [
    4, 8, 16, 32, 64, 96, 128, 160, //
    202, 254, 380, 508, 762, 1016, 2034, 4068
  ];

  Int8List synth(int cycles) {
    final buf = Int8List(cycles);

    if (!enabled || lengthCounter == 0) {
      buf.fillRange(0, buf.length, 0);
      return buf;
    }

    for (int i = 0; i < buf.length; i++) {
      if (counter == 0) {
        final nextBit = reg & 0x01 ^ (short ? (reg >> 1) : (reg >> 5)) & 0x01;
        reg >>= 1;
        reg |= nextBit << 15;
        counter = _table[timer];
      }
      buf[i] = ((reg & 0x01) == 0) ? 0 : (reg & 0xf) * envelope.volume ~/ 15;
      counter--;
    }

    return buf;
  }
}

class Apu {
  late final Bus bus;

  int cycle = 0;

  final pulse0 = _PulseWave(0);
  final pulse1 = _PulseWave(1);
  final triangle = TriangleWave();
  final noise = NoiseWave();

  bool dpcmEnabled = false;

  bool frameIRQHold = false;

  void write(int reg, int val) {
    switch (reg) {
      case 0x4000:
        pulse0.dutyType = val >> 6;
        pulse0.halt = val & 0x20 != 0;
        pulse0.envelope.prepare(
            disabled: (val & 0x10) != 0, loop: pulse0.halt, n: val & 0x0f);
        return;
      case 0x4001:
        pulse0.sweep.enabled = (val & 0x80) != 0;
        pulse0.sweep.period = (val & 0x70) >> 4;
        pulse0.sweep.negate = (val & 0x08) != 0;
        pulse0.sweep.shift = val & 0x07;
        return;
      case 0x4002:
        pulse0.sweep.freq = pulse0.sweep.freq & 0x700 | val;
        return;
      case 0x4003:
        pulse0.sweep.freq = pulse0.sweep.freq & 0xff | ((val & 0x07) << 8);
        pulse0.setLength(val >> 3);
        pulse0.noteOn();
        return;

      case 0x4004:
        pulse1.dutyType = val >> 6;
        pulse1.halt = val & 0x20 != 0;
        pulse1.envelope.prepare(
            disabled: (val & 0x10) != 0, loop: pulse1.halt, n: val & 0x0f);
        return;
      case 0x4005:
        pulse1.sweep.enabled = val & 0x80 != 0;
        pulse1.sweep.period = (val & 0x70) >> 4;
        pulse1.sweep.negate = val & 0x8 != 0;
        pulse1.sweep.shift = val & 0x7;
        return;
      case 0x4006:
        pulse1.sweep.freq = pulse1.sweep.freq & 0x700 | val;
        return;
      case 0x4007:
        pulse1.sweep.freq = pulse1.sweep.freq & 0xff | ((val & 0x07) << 8);
        pulse1.setLength(val >> 3);
        pulse1.noteOn();
        return;

      case 0x4008:
        triangle.halt = val & 0x80 != 0;
        return;
      case 0x4009:
        return;
      case 0x400a:
        triangle.freq = triangle.freq & 0x700 | val;
        return;
      case 0x400b:
        triangle.freq = triangle.freq & 0xff | ((val & 0x07) << 8);
        triangle.setLength(val >> 3);
        triangle.prepare();
        return;

      case 0x400c:
        noise.halt = val & 0x20 != 0;
        noise.envelope.prepare(
            disabled: (val & 0x10) != 0, loop: noise.halt, n: val & 0x0f);
        return;
      case 0x400d:
        return;
      case 0x400e:
        noise.short = val & 0x80 != 0;
        noise.timer = val & 0x0f;
        return;
      case 0x400f:
        noise.setLength(val >> 3);
        noise.envelope.keyOn();
        return;
      case 0x4010:
      case 0x4011:
      case 0x4012:
      case 0x4013:
      case 0x4014:
        return;
      case 0x4015:
        pulse0.enabled = val & 0x01 != 0;
        pulse1.enabled = val & 0x02 != 0;
        triangle.enabled = val & 0x04 != 0;
        noise.enabled = val & 0x08 != 0;
        dpcmEnabled = val & 0x10 != 0;
        return;
      case 0x4017:
        frameCounterMode0 = (val & 0x80) == 0;
        if ((val & 0x40) != 0) {
          frameIRQHold = false;
          bus.releaseIRQ();
        }
        frameCountTick = 0;
        return;
      default:
        log("Unsupported apu write at 0x${hex16(reg)}");
        return;
    }
  }

  int read(int reg) {
    switch (reg) {
      case 0x4015:
        final result = (frameIRQHold ? 0x40 : 0) |
            (pulse0.lengthCounter > 0 ? 0x01 : 0) |
            (pulse1.lengthCounter > 0 ? 0x02 : 0) |
            (triangle.lengthCounter > 0 ? 0x04 : 0) |
            (noise.lengthCounter > 0 ? 0x08 : 0);
        frameIRQHold = false;
        bus.releaseIRQ();
        return result;

      case 0x4017:
        return 0;
      default:
        log("Unsupported apu read at 0x${hex16(reg)}");
        return 0;
    }
  }

  // 1cycle = 1.78MHz = 0.56us
  // 40.58 cpu cycle ~= 44100Hz = 22.67us
  // 29830 cpu cycle = 1/60s = 16.6ms
  //
  // rendar 1 frame = 60Hz
  // 735 samples = 1/60 sec * 44100 Hz
  static const execCycles = 29830 ~/ 2 + 1000;
  static final pulseOutTable =
      List<double>.generate(32, (n) => n == 0 ? 0 : 95.52 / (8128.0 / n + 100));
  static final tndOutTable = List<double>.generate(
      204, (n) => n == 0 ? 0 : 163.67 / (24329.0 / n + 100));

  final buffer =
      Float32List.fromList(List.filled(execCycles, 0.0, growable: false));

  void exec() {
    var bufferIndex = 0;
    final ticksInFrame = frameCounterMode0 ? 4 : 5;
    final tickCycles = execCycles ~/ ticksInFrame;

    for (int tick = 0; tick < ticksInFrame; tick++) {
      cycle += tickCycles;
      final p0 = pulse0.synth(tickCycles);
      final p1 = pulse1.synth(tickCycles);
      final t = triangle.synth(tickCycles);
      final n = noise.synth(tickCycles);
      final d = synthDPCM(tickCycles);

      for (int i = 0; i < tickCycles; i++) {
        final pulseOut = pulseOutTable[p0[i] + p1[i]];
        final elseOut = tndOutTable[t[i] * 3 + n[i] * 2 + d[i]];
        buffer[bufferIndex++] = pulseOut + elseOut;
      }

      countApuFrame();
    }
  }

  void countEnvelope() {
    pulse0.envelope.count();
    pulse1.envelope.count();
    noise.envelope.count();
  }

  void countLength() {
    pulse0.countLength();
    pulse0.sweep.sweep();
    pulse1.countLength();
    pulse1.sweep.sweep();
    triangle.countLength();
    noise.countLength();
  }

  bool frameCounterMode0 = false;
  int frameCountTick = 0;

  // called almost 240Hz or 192Hz
  void countApuFrame() {
    if (frameCounterMode0) {
      countEnvelope();
      if (frameCountTick == 1 || frameCountTick == 3) {
        countLength();
      }
      if (frameCountTick == 3) {
        frameIRQHold = true;
        bus.holdIRQ();
      }
    } else {
      if (frameCountTick != 3) {
        countEnvelope();
      }
      if (frameCountTick == 1 || frameCountTick == 4) {
        countLength();
      }
    }

    frameCountTick++;
    if (frameCountTick == (frameCounterMode0 ? 4 : 5)) {
      frameCountTick = 0;
    }
  }

  Int8List synthDPCM(int cycles) {
    final buf = Int8List(cycles);
    buf.fillRange(0, buf.length, 0);
    return buf;
  }
}
