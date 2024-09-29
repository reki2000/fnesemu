// Dart imports:
import 'dart:developer';
import 'dart:typed_data';

// Project imports:
import '../../../util.dart';
import '../nes.dart';
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

  bool _enabled = false;
  bool _negate = false;
  int _period = 0;
  int _shift = 0;

  int _counter = 0;
  final int _adjust;

  _SweepUnit(
    this._adjust,
  );

  String debug() {
    return "${_enabled ? (_negate ? '-' : '+') : ' '}$_shift:"
        "$_counter/$_period ${hex16(freq)}";
  }

  void reload(int val) {
    _enabled = bit7(val);
    _period = (val & 0x70) >> 4;
    _negate = bit3(val);
    _shift = val & 0x07;
  }

  void sweep() {
    if (!_enabled || _shift == 0) {
      return;
    }

    if (_counter == 0) {
      if (_negate) {
        freq -= (freq >> _shift);
        freq -= _adjust;
      } else {
        freq += (freq >> _shift);
      }

      if (freq > 0x7ff) {
        freq = 0x7ff;
      } else if (freq < 0) {
        freq = 0;
      }

      _counter = _period + 1;
    } else {
      _counter--;
    }
    return;
  }

  void keyOn() {
    _counter = _period + 1;
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
      return buf;
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
  int _timer = 0;
  int _index = 0;

  static final table = List.generate(16, (index) => 15 - index)
    ..addAll(List.generate(16, (index) => index));

  void prepare() {
    _timer = freq + 1;
    //_index = 0;
    _needLinearReload = true;
  }

  int linearReload = 0;
  bool linearControl = false;

  int _linear = 0;
  bool _needLinearReload = false;

  void countLinear() {
    if (_needLinearReload) {
      _linear = linearReload;
    } else if (_linear > 0) {
      _linear--;
    }

    if (!linearControl) {
      _needLinearReload = false;
    }
  }

  Int8List synth(int cycles) {
    final buf = Int8List(cycles);

    if (!enabled ||
        _linear == 0 ||
        lengthCounter == 0 ||
        // freq == 0x7ff ||
        freq < 2) {
      return buf;
    }

    for (int i = 0; i < buf.length; i++) {
      if (_timer <= 0) {
        _timer = freq + 1;
        _index = (_index + 1) & 0x1f;
      }
      buf[i] = table[_index];
      _timer -= 2;
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
      buf[i] = !bit0(reg) ? 0 : (reg & 0xf) * envelope.volume ~/ 15;
      counter--;
    }

    return buf;
  }
}

class DPCMWave {
  final int Function(int) fetch;
  final void Function() interrupt;
  bool enabled = false;

  DPCMWave(this.fetch, this.interrupt);

  int _initAddress = 0;
  int _initLength = 0;

  bool _loop = false;
  bool _irqEnabled = false;
  int _initTimer = 0;

  int _address = 0;
  int _length = 0;
  int _sample = 0;
  bool _silence = true;

  final _timerTable = [
    // these are cpu cycles. 1 apu cycles = 2 cpu cycles
    428, 380, 340, 320, 286, 254, 226, 214, 190, 160, 142, 128, 106, 84, 72, 54
  ];
  int _timer = 0;

  int _counter = 0;
  int _deltaCounter = 0;

  set mode(int val) {
    _irqEnabled = bit7(val);
    _loop = bit6(val);
    _initTimer = _timerTable[val & 0x0f] ~/ 2;
    _timer = _initTimer;
  }

  set address(int addr) {
    _initAddress = (addr << 6) + 0xc000;
    _address = _initAddress;
  }

  set length(int length) {
    _initLength = (length << 4) + 1;
    _length = _initLength;
  }

  int get length => _length;

  set deltaCounter(int counter) {
    _deltaCounter = counter;
  }

  bool _fillSampleBuffer() {
    if (_length == 0) {
      if (!_loop) {
        return true; // true means no sample data
      }

      _address = _initAddress;
      _length = _initLength;
      if (_irqEnabled) {
        interrupt();
      }
    }

    _sample = fetch(_address);

    _address++;
    _address &= 0xffff;
    _length--;
    return false;
  }

  void _updateDeltaCounter() {
    final bit = _sample & 0x01;
    _sample >>= 1;

    if (bit == 0) {
      if (_deltaCounter > 1) {
        _deltaCounter -= 2;
      }
    } else {
      if (_deltaCounter < 126) {
        _deltaCounter += 2;
      }
    }
  }

  Int8List synth(int cycles) {
    final buf = Int8List(cycles);
    if (!enabled) {
      return buf;
    }

    for (int i = 0; i < buf.length; i++) {
      if (_timer == 0) {
        if (!_silence) {
          _updateDeltaCounter();
        }

        if (_counter == 0) {
          _silence = _fillSampleBuffer();
          _counter = 7;
        } else {
          _counter--;
        }

        _timer = _initTimer;
      } else {
        _timer--;
      }

      buf[i] = _silence ? 0 : _deltaCounter;
    }

    return buf;
  }
}

/// Emulates NES APU
class Apu {
  late final Bus _bus;

  Apu(bus) {
    _bus = bus;
    _bus.apu = this;
    dpcm = DPCMWave(_bus.read, _bus.holdIrq);
  }

  void reset() {
    cycle = 0;
    frameIrqHold = false;
    frameIrqEnabled = false;
    frameCounterMode0 = false;
    frameCountTick = 0;
    write(0x4015, 0);
  }

  int cycle = 0;

  final pulse0 = _PulseWave(0);
  final pulse1 = _PulseWave(1);
  final triangle = TriangleWave();
  final noise = NoiseWave();
  late final DPCMWave dpcm;

  bool frameIrqHold = false;
  bool frameIrqEnabled = false;
  bool frameCounterMode0 = false;
  int frameCountTick = 0;

  void write(int reg, int val) {
    switch (reg) {
      // pulse wave 0
      case 0x4000:
        pulse0.dutyType = val >> 6;
        pulse0.halt = bit5(val);
        pulse0.envelope
            .prepare(disabled: bit4(val), loop: pulse0.halt, n: val & 0x0f);
        return;

      case 0x4001:
        pulse0.sweep.reload(val);
        return;

      case 0x4002:
        pulse0.sweep.freq = pulse0.sweep.freq & 0x700 | val;
        return;

      case 0x4003:
        pulse0.sweep.freq = (pulse0.sweep.freq & 0xff) | ((val & 0x07) << 8);
        pulse0.setLength(val >> 3);
        pulse0.noteOn();
        return;

      // pulse wave 1
      case 0x4004:
        pulse1.dutyType = val >> 6;
        pulse1.halt = bit5(val);
        pulse1.envelope
            .prepare(disabled: bit4(val), loop: pulse1.halt, n: val & 0x0f);
        return;

      case 0x4005:
        pulse1.sweep.reload(val);
        return;

      case 0x4006:
        pulse1.sweep.freq = pulse1.sweep.freq & 0x700 | val;
        return;

      case 0x4007:
        pulse1.sweep.freq = (pulse1.sweep.freq & 0xff) | ((val & 0x07) << 8);
        pulse1.setLength(val >> 3);
        pulse1.noteOn();
        return;

      // triangle wave
      case 0x4008:
        triangle.halt = bit7(val);
        triangle.linearControl = bit7(val);
        triangle.linearReload = val & 0x7f;
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

      // noise wave
      case 0x400c:
        noise.halt = bit5(val);
        noise.envelope
            .prepare(disabled: bit4(val), loop: noise.halt, n: val & 0x0f);
        return;

      case 0x400d:
        return;

      case 0x400e:
        noise.short = bit7(val);
        noise.timer = val & 0x0f;
        return;

      case 0x400f:
        noise.setLength(val >> 3);
        noise.envelope.keyOn();
        return;

      // DPCM
      case 0x4010:
        dpcm.mode = val;
        return;

      case 0x4011:
        dpcm.deltaCounter = val;
        return;

      case 0x4012:
        dpcm.address = val;
        return;

      case 0x4013:
        dpcm.length = val;
        return;

      case 0x4014:
        return;

      // control
      case 0x4015:
        pulse0.enabled = bit0(val);
        pulse1.enabled = bit1(val);
        triangle.enabled = bit2(val);
        noise.enabled = bit3(val);
        dpcm.enabled = bit4(val);
        return;

      case 0x4017:
        frameCounterMode0 = !bit7(val);
        if (bit6(val)) {
          frameIrqEnabled = false;
          releaseFrameIRQ();
        } else {
          frameIrqEnabled = true;
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
        final result = (frameIrqHold ? 0x80 : 0) | // shold be DMC.IRQHold
            (frameIrqHold ? 0x40 : 0) |
            (pulse0.lengthCounter > 0 ? 0x01 : 0) |
            (pulse1.lengthCounter > 0 ? 0x02 : 0) |
            (triangle.lengthCounter > 0 ? 0x04 : 0) |
            (noise.lengthCounter > 0 ? 0x08 : 0) |
            (dpcm.length > 0 ? 0x10 : 0);
        releaseFrameIRQ();
        return result;

      case 0x4017:
        return 0;

      default:
        log("Unsupported apu read at 0x${hex16(reg)}");
        return 0;
    }
  }

  void releaseFrameIRQ() {
    frameIrqHold = false;
    _bus.releaseIrq();
  }

  void setFrameIRQ() {
    if (frameIrqEnabled) {
      frameIrqHold = true;
      _bus.holdIrq();
    }
  }

  //                cpu cycle  frequency   duration
  // cpu cycle:             1    1.78MHz     0.56us
  // audio samples:     40.58    44100Hz    22.67us
  // 1 NTSCframe:       29830       60Hz     16.6ms = 735 audio samples
  //                    29754 = (261 * 114)

  // generates sound outout for 1 frame at one APU emulation
  // 29820 (cpu cycles @60Hz) / 2 (apu:cpu cycle ratio)
  static const _frameCycles =
      Nes.scanlinesInFrame_ * Nes.cpuCyclesInScanline ~/ 2;

  // output volume conversion table for pulse channles
  static final _pulseOutTable =
      List<double>.generate(32, (n) => n == 0 ? 0 : 95.52 / (8128.0 / n + 100));

  // output volume conversion table for tnd: triange, noise, dpcm channels
  static final _tndOutTable = List<double>.generate(
      204, (n) => n == 0 ? 0 : 163.67 / (24329.0 / n + 100));

  // counter for APU frame: it has 4 or 5 frames in 1 display frame
  int apuFrameCounter = _frameCycles ~/ 4;

  var buffer = Float32List(0);

  /// Generates APU 1Frame output and set it to the apu output buffer
  Float32List exec(int cycles) {
    if (buffer.length != cycles) {
      buffer = Float32List(cycles);
    }

    var bufferIndex = 0;

    int restCycles = cycles;

    while (restCycles > 0) {
      var consumeCycles = restCycles;
      var countApuFrame = false;

      if (apuFrameCounter < restCycles) {
        consumeCycles = apuFrameCounter;
        apuFrameCounter = _frameCycles ~/ (frameCounterMode0 ? 4 : 5);

        countApuFrame = true;
      } else {
        apuFrameCounter -= consumeCycles;
      }

      final p0 = pulse0.synth(consumeCycles);
      final p1 = pulse1.synth(consumeCycles);
      final t = triangle.synth(consumeCycles);
      final n = noise.synth(consumeCycles);
      final d = dpcm.synth(consumeCycles);

      for (int i = 0; i < consumeCycles; i++) {
        final pulseOut = _pulseOutTable[p0[i] + p1[i]];
        final elseOut = _tndOutTable[t[i] * 3 + n[i] * 2 + d[i]];
        buffer[bufferIndex++] = (pulseOut + elseOut) * 2 - 1.0;
      }

      if (countApuFrame) {
        _countApuFrame();
      }

      restCycles -= consumeCycles;
      cycle += consumeCycles;
    }

    return buffer;
  }

  void _countEnvelope() {
    pulse0.envelope.count();
    pulse1.envelope.count();
    triangle.countLinear();
    noise.envelope.count();
  }

  void _countLength() {
    pulse0.countLength();
    pulse0.sweep.sweep();
    pulse1.countLength();
    pulse1.sweep.sweep();
    triangle.countLength();
    noise.countLength();
  }

  // called almost 240Hz or 192Hz
  void _countApuFrame() {
    if (frameCounterMode0) {
      _countEnvelope();
      if (frameCountTick == 1 || frameCountTick == 3) {
        _countLength();
      }
      if (frameCountTick == 3) {
        setFrameIRQ();
      }
    } else {
      if (frameCountTick != 3) {
        _countEnvelope();
      }
      if (frameCountTick == 1 || frameCountTick == 4) {
        _countLength();
      }
    }

    frameCountTick++;
    if (frameCountTick == (frameCounterMode0 ? 4 : 5)) {
      frameCountTick = 0;
    }
  }
}
