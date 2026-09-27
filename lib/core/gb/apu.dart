import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';

/// length counter / envelope shared by the channels
abstract class _Channel {
  bool enabled = false;
  bool dacEnabled = false;
  int length = 0;
  bool lengthEnabled = false;

  // envelope
  int initialVolume = 0;
  bool envelopeUp = false;
  int envelopePeriod = 0;
  int volume = 0;
  int _envelopeTimer = 0;

  int get maxLength => 64;

  /// digital output 0-15
  int get output;

  void step(int clocks);

  void clockLength() {
    if (lengthEnabled && length > 0) {
      length--;
      if (length == 0) {
        enabled = false;
      }
    }
  }

  /// NRx4 write. [firstHalf] is true when the next frame sequencer step
  /// does not clock the length counter
  void writeControl(int data, bool firstHalf) {
    final wasEnabled = lengthEnabled;
    lengthEnabled = data.bit6;

    // enabling the length counter clocks it once in the first half
    if (!wasEnabled && lengthEnabled && firstHalf && length > 0) {
      length--;
      if (length == 0 && !data.bit7) {
        enabled = false;
      }
    }

    if (data.bit7) {
      final reload = length == 0;
      trigger();
      if (reload && lengthEnabled && firstHalf) {
        length--;
      }
    }
  }

  void clockEnvelope() {
    if (envelopePeriod == 0) {
      return;
    }
    if (--_envelopeTimer <= 0) {
      _envelopeTimer = envelopePeriod;
      if (envelopeUp && volume < 15) {
        volume++;
      } else if (!envelopeUp && volume > 0) {
        volume--;
      }
    }
  }

  void writeEnvelope(int data) {
    initialVolume = data.shr4;
    envelopeUp = data.bit3;
    envelopePeriod = data.mask3;
    dacEnabled = data & 0xf8 != 0;
    if (!dacEnabled) {
      enabled = false;
    }
  }

  void trigger() {
    enabled = dacEnabled;
    if (length == 0) {
      length = maxLength;
    }
    volume = initialVolume;
    _envelopeTimer = envelopePeriod;
  }

  void reset() {
    enabled = false;
    dacEnabled = false;
    length = 0;
    lengthEnabled = false;
    initialVolume = 0;
    envelopeUp = false;
    envelopePeriod = 0;
    volume = 0;
    _envelopeTimer = 0;
  }
}

class _Square extends _Channel {
  static const _duties = [
    [0, 0, 0, 0, 0, 0, 0, 1],
    [1, 0, 0, 0, 0, 0, 0, 1],
    [1, 0, 0, 0, 0, 1, 1, 1],
    [0, 1, 1, 1, 1, 1, 1, 0],
  ];

  final bool hasSweep;

  int duty = 0;
  int frequency = 0;
  int _dutyPos = 0;
  int _timer = 0;

  // sweep
  int sweepPeriod = 0;
  bool sweepNegate = false;
  int sweepShift = 0;
  int _sweepTimer = 0;
  int _shadow = 0;
  bool _sweepEnabled = false;
  bool _negateUsed = false;

  _Square(this.hasSweep);

  @override
  int get output => enabled && _duties[duty][_dutyPos] != 0 ? volume : 0;

  @override
  void step(int clocks) {
    _timer -= clocks;
    while (_timer <= 0) {
      _timer += (2048 - frequency) * 4;
      _dutyPos = (_dutyPos + 1).mask3;
    }
  }

  int _calcSweep() {
    final delta = _shadow.shr(sweepShift);
    final f = sweepNegate ? _shadow - delta : _shadow + delta;
    if (sweepNegate) {
      _negateUsed = true;
    }
    if (f > 2047) {
      enabled = false;
    }
    return f;
  }

  void clockSweep() {
    if (--_sweepTimer > 0) {
      return;
    }
    _sweepTimer = sweepPeriod == 0 ? 8 : sweepPeriod;

    if (_sweepEnabled && sweepPeriod != 0) {
      final f = _calcSweep();
      if (f <= 2047 && sweepShift != 0) {
        _shadow = f;
        frequency = f;
        _calcSweep();
      }
    }
  }

  void writeSweep(int data) {
    sweepPeriod = data.shr4.mask3;
    final negate = data.bit3;
    if (_negateUsed && sweepNegate && !negate) {
      enabled = false;
    }
    sweepNegate = negate;
    sweepShift = data.mask3;
  }

  @override
  void trigger() {
    super.trigger();
    _timer = (2048 - frequency) * 4;

    if (hasSweep) {
      _shadow = frequency;
      _sweepTimer = sweepPeriod == 0 ? 8 : sweepPeriod;
      _sweepEnabled = sweepPeriod != 0 || sweepShift != 0;
      _negateUsed = false;
      if (sweepShift != 0) {
        _calcSweep();
      }
    }
  }

  @override
  void reset() {
    super.reset();
    duty = 0;
    frequency = 0;
    _dutyPos = 0;
    _timer = 0;
    sweepPeriod = 0;
    sweepNegate = false;
    sweepShift = 0;
    _sweepTimer = 0;
    _shadow = 0;
    _sweepEnabled = false;
    _negateUsed = false;
  }
}

class _Wave extends _Channel {
  final ram = Uint8List(16);

  int level = 0;
  int frequency = 0;
  int _position = 0;
  int _timer = 0;
  int _sample = 0;

  static const _shifts = [4, 0, 1, 2];

  @override
  int get maxLength => 256;

  @override
  int get output => enabled ? _sample.shr(_shifts[level]) : 0;

  @override
  void step(int clocks) {
    _timer -= clocks;
    while (_timer <= 0) {
      _timer += (2048 - frequency) * 2;
      _position = (_position + 1).mask5;
      final byte = ram[_position.shr1];
      _sample = !_position.bit0 ? byte.shr4 : byte.mask4;
    }
  }

  @override
  void trigger() {
    enabled = dacEnabled;
    if (length == 0) {
      length = maxLength;
    }
    _timer = (2048 - frequency) * 2 + 6;
    _position = 0;
  }

  @override
  void reset() {
    super.reset();
    level = 0;
    frequency = 0;
    _position = 0;
    _timer = 0;
    _sample = 0;
  }
}

class _Noise extends _Channel {
  static const _divisors = [8, 16, 32, 48, 64, 80, 96, 112];

  int clockShift = 0;
  bool shortMode = false;
  int divisorCode = 0;
  int _lfsr = 0x7fff;
  int _timer = 0;

  int get _period => _divisors[divisorCode].shl(clockShift);

  @override
  int get output => enabled && !_lfsr.bit0 ? volume : 0;

  @override
  void step(int clocks) {
    _timer -= clocks;
    while (_timer <= 0) {
      _timer += _period;
      final x = (_lfsr ^ _lfsr.shr1).mask1;
      _lfsr = _lfsr.shr1 | x.shl14;
      if (shortMode) {
        _lfsr = _lfsr & ~0x40 | x.shl6;
      }
    }
  }

  void writePolynomial(int data) {
    clockShift = data.shr4;
    shortMode = data.bit3;
    divisorCode = data.mask3;
  }

  @override
  void trigger() {
    super.trigger();
    _lfsr = 0x7fff;
    _timer = _period;
  }

  @override
  void reset() {
    super.reset();
    clockShift = 0;
    shortMode = false;
    divisorCode = 0;
    _lfsr = 0x7fff;
    _timer = 0;
  }
}

/// sound unit with 2 square, 1 wave and 1 noise channels
class Apu {
  static const clockHz = 4194304;
  static const _clocksPerSample = 96;
  static const sampleRate = clockHz ~/ _clocksPerSample; // 43690Hz

  static const _readMasks = [
    0x80, 0x3f, 0x00, 0xff, 0xbf, // NR10-NR14
    0xff, 0x3f, 0x00, 0xff, 0xbf, // NR20-NR24
    0x7f, 0xff, 0x9f, 0xff, 0xbf, // NR30-NR34
    0xff, 0xff, 0x00, 0x00, 0xbf, // NR40-NR44
    0x00, 0x00, 0x70, // NR50-NR52
  ];

  final _ch1 = _Square(true);
  final _ch2 = _Square(false);
  final _ch3 = _Wave();
  final _ch4 = _Noise();

  late final List<_Channel> _channels = [_ch1, _ch2, _ch3, _ch4];

  final _regs = Uint8List(0x17); // FF10-FF26

  bool _power = true;
  int _frameStep = 0;

  // output buffer (stereo interleaved)
  static const bufferFrames = 512;
  final buffer = Float32List(bufferFrames * 2);
  int bufferIndex = 0;

  int _sampleClocks = 0;
  double _accL = 0, _accR = 0;
  int _accCount = 0;
  double _capL = 0, _capR = 0;

  void reset() {
    for (final ch in _channels) {
      ch.reset();
    }
    _ch3.ram.fillRange(0, 16, 0);
    _regs.fillRange(0, _regs.length, 0);
    _power = true;
    _frameStep = 0;
    bufferIndex = 0;
    _sampleClocks = 0;
    _accL = _accR = 0;
    _accCount = 0;
    _capL = _capR = 0;

    // register values after the boot program
    const init = {
      0xff10: 0x80, 0xff11: 0xbf, 0xff12: 0xf3, 0xff14: 0xbf, //
      0xff16: 0x3f, 0xff19: 0xbf, 0xff1a: 0x7f, 0xff1b: 0xff, //
      0xff1c: 0x9f, 0xff1e: 0xbf, 0xff20: 0xff, 0xff23: 0xbf, //
      0xff24: 0x77, 0xff25: 0xf3,
    };
    init.forEach((addr, data) => write(addr, data));
    _ch1.enabled = true; // the boot program played a sound on channel 1
  }

  /// 512Hz frame sequencer, clocked by the divider
  void clockFrameSequencer() {
    if (!_power) {
      return;
    }

    if (_frameStep.isEven) {
      for (final ch in _channels) {
        ch.clockLength();
      }
    }
    if (_frameStep == 2 || _frameStep == 6) {
      _ch1.clockSweep();
    }
    if (_frameStep == 7) {
      _ch1.clockEnvelope();
      _ch2.clockEnvelope();
      _ch4.clockEnvelope();
    }

    _frameStep = (_frameStep + 1).mask3;
  }

  /// one machine cycle
  void tick() {
    if (_power) {
      _ch1.step(4);
      _ch2.step(4);
      _ch3.step(4);
      _ch4.step(4);
      _mix();
    }

    _sampleClocks += 4;
    if (_sampleClocks >= _clocksPerSample) {
      _sampleClocks -= _clocksPerSample;
      _emitSample();
    }
  }

  // DAC output in -1.0 .. 1.0, 0.0 when the DAC is off
  static double _dac(_Channel ch) =>
      ch.dacEnabled ? ch.output / 7.5 - 1.0 : 0.0;

  void _mix() {
    final nr51 = _regs[0x15];
    var l = 0.0, r = 0.0;

    for (int i = 0; i < 4; i++) {
      final ch = _channels[i];
      if (nr51 & (0x11 << i) == 0) {
        continue;
      }
      final v = _dac(ch);
      if (nr51 & (0x10 << i) != 0) {
        l += v;
      }
      if (nr51 & (0x01 << i) != 0) {
        r += v;
      }
    }

    final nr50 = _regs[0x14];
    _accL += l * (nr50.shr4.mask3 + 1);
    _accR += r * (nr50.mask3 + 1);
    _accCount++;
  }

  void _emitSample() {
    var l = 0.0, r = 0.0;
    if (_accCount > 0) {
      // 4 channels x volume 8
      l = _accL / _accCount / 32;
      r = _accR / _accCount / 32;
    }
    _accL = _accR = 0;
    _accCount = 0;

    // high pass filter to remove DC offset
    final outL = l - _capL;
    _capL = l - outL * 0.996;
    final outR = r - _capR;
    _capR = r - outR * 0.996;

    if (bufferIndex < buffer.length) {
      buffer[bufferIndex++] = outL;
      buffer[bufferIndex++] = outR;
    }
  }

  bool get bufferFull => bufferIndex >= buffer.length;

  /// returns the rendered samples and clears the buffer
  Float32List takeBuffer() {
    final out = Float32List.fromList(buffer.sublist(0, bufferIndex));
    bufferIndex = 0;
    return out;
  }

  int read(int addr) {
    if (addr >= 0xff30) {
      return _ch3.ram[addr - 0xff30];
    }
    if (addr > 0xff26) {
      return 0xff;
    }
    if (addr == 0xff26) {
      var v = (_power ? 0x80 : 0) | 0x70;
      for (int i = 0; i < 4; i++) {
        if (_channels[i].enabled) {
          v |= 1 << i;
        }
      }
      return v;
    }
    final i = addr - 0xff10;
    return _regs[i] | _readMasks[i];
  }

  void write(int addr, int data) {
    if (addr >= 0xff30) {
      _ch3.ram[addr - 0xff30] = data;
      return;
    }
    if (addr > 0xff26) {
      return;
    }

    if (addr == 0xff26) {
      final on = data.bit7;
      if (_power && !on) {
        // length counters are not affected by power off
        final lengths = _channels.map((ch) => ch.length).toList();
        for (int a = 0xff10; a < 0xff26; a++) {
          write(a, 0);
        }
        for (int i = 0; i < 4; i++) {
          _channels[i].enabled = false;
          _channels[i].length = lengths[i];
        }
      } else if (!_power && on) {
        _frameStep = 0;
      }
      _power = on;
      return;
    }

    if (!_power) {
      // only length counters are writable while powered off
      switch (addr) {
        case 0xff11:
          _ch1.length = 64 - data.mask6;
        case 0xff16:
          _ch2.length = 64 - data.mask6;
        case 0xff1b:
          _ch3.length = 256 - data;
        case 0xff20:
          _ch4.length = 64 - data.mask6;
      }
      return;
    }

    _regs[addr - 0xff10] = data;

    switch (addr) {
      // channel 1
      case 0xff10:
        _ch1.writeSweep(data);
      case 0xff11:
        _ch1.duty = data.shr6;
        _ch1.length = 64 - data.mask6;
      case 0xff12:
        _ch1.writeEnvelope(data);
      case 0xff13:
        _ch1.frequency = (_ch1.frequency & 0x700) | data;
      case 0xff14:
        _ch1.frequency = _ch1.frequency.mask8 | data.mask3.shl8;
        _ch1.writeControl(data, _frameStep.isOdd);

      // channel 2
      case 0xff16:
        _ch2.duty = data.shr6;
        _ch2.length = 64 - data.mask6;
      case 0xff17:
        _ch2.writeEnvelope(data);
      case 0xff18:
        _ch2.frequency = (_ch2.frequency & 0x700) | data;
      case 0xff19:
        _ch2.frequency = _ch2.frequency.mask8 | data.mask3.shl8;
        _ch2.writeControl(data, _frameStep.isOdd);

      // channel 3
      case 0xff1a:
        _ch3.dacEnabled = data.bit7;
        if (!_ch3.dacEnabled) {
          _ch3.enabled = false;
        }
      case 0xff1b:
        _ch3.length = 256 - data;
      case 0xff1c:
        _ch3.level = data.shr5.mask2;
      case 0xff1d:
        _ch3.frequency = (_ch3.frequency & 0x700) | data;
      case 0xff1e:
        _ch3.frequency = _ch3.frequency.mask8 | data.mask3.shl8;
        _ch3.writeControl(data, _frameStep.isOdd);

      // channel 4
      case 0xff20:
        _ch4.length = 64 - data.mask6;
      case 0xff21:
        _ch4.writeEnvelope(data);
      case 0xff22:
        _ch4.writePolynomial(data);
      case 0xff23:
        _ch4.writeControl(data, _frameStep.isOdd);
    }
  }

  String dump() {
    final regs = List.generate(0x17, (i) => read(0xff10 + i).x2).join(" ");
    final status = _channels
        .map((ch) => "${ch.enabled ? "on " : "off"} len:${ch.length.d3} "
            "vol:${ch.volume.d2}")
        .join(" | ");
    return "apu: $regs\n$status\n";
  }
}
