import 'dart:math' as math;
import 'dart:typed_data';

class _Envelope {
  int control = 0x80, gain = 0, timer = 0;
  void write(int value) {
    control = value;
    timer = 0;
    if (value & 0x80 != 0) gain = value & 0x3f;
  }

  void tick(int masterSpeed) {
    if (control & 0x80 != 0) return;
    timer++;
    final period = 8 * ((control & 0x3f) + 1) * (masterSpeed + 1);
    if (timer < period) return;
    timer = 0;
    if (control & 0x40 != 0) {
      if (gain < 32) gain++;
    } else if (gain > 0) {
      gain--;
    }
  }
}

/// RP2C33 wavetable, two envelopes and signed modulation counter.
class FdsAudio {
  final wave = Uint8List(64), modulation = Uint8List(64);
  final _volume = _Envelope(), _modGain = _Envelope();
  int _pitch = 0, _modPitch = 0, _wavePhase = 0, _modPhase = 0;
  int _modCounter = 0, _masterSpeed = 0xe8, _masterVolume = 0;
  bool _waveHalt = true,
      _modHalt = true,
      _envelopeHalt = true,
      _writeWave = false;
  double _filtered = 0;

  void reset() {
    wave.fillRange(0, 64, 0);
    modulation.fillRange(0, 64, 0);
    _volume.write(0x80);
    _modGain.write(0x80);
    _pitch = _modPitch = _wavePhase = _modPhase = _modCounter = 0;
    _masterSpeed = 0xe8;
    _masterVolume = 0;
    _waveHalt = _modHalt = _envelopeHalt = true;
    _writeWave = false;
    _filtered = 0;
  }

  int read(int address) {
    if (address >= 0x4040 && address <= 0x407f) {
      return wave[_writeWave ? address & 63 : _wavePhase >> 18];
    }
    return switch (address) {
      0x4090 => 0x40 | _volume.gain,
      0x4092 => 0x40 | _modGain.gain,
      _ => 0xff,
    };
  }

  void write(int address, int value) {
    if (address >= 0x4040 && address <= 0x407f) {
      if (_writeWave) wave[address & 63] = value & 63;
      return;
    }
    switch (address) {
      case 0x4080:
        _volume.write(value);
      case 0x4082:
        _pitch = (_pitch & 0xf00) | value;
      case 0x4083:
        _pitch = (_pitch & 0xff) | (value & 15) << 8;
        _waveHalt = value & 0x80 != 0;
        _envelopeHalt = value & 0x40 != 0;
        if (_waveHalt) _wavePhase = 0;
        if (_envelopeHalt) _volume.timer = _modGain.timer = 0;
      case 0x4084:
        _modGain.write(value);
      case 0x4085:
        _modCounter = ((value + 64) & 127) - 64;
      case 0x4086:
        _modPitch = (_modPitch & 0xf00) | value;
      case 0x4087:
        _modPitch = (_modPitch & 0xff) | (value & 15) << 8;
        _modHalt = value & 0x80 != 0;
        if (_modHalt) _modPhase &= ~0xffff;
      case 0x4088:
        if (_modHalt) {
          final index = _modPhase >> 16;
          modulation[index] = modulation[(index + 1) & 63] = value & 7;
          _modPhase = (_modPhase + (2 << 16)) & 0x3fffff;
        }
      case 0x4089:
        _writeWave = value & 0x80 != 0;
        _masterVolume = value & 3;
      case 0x408a:
        _masterSpeed = value;
    }
  }

  void _clock() {
    if (!_waveHalt && !_envelopeHalt) {
      _volume.tick(_masterSpeed);
      _modGain.tick(_masterSpeed);
    }
    if (!_modHalt) {
      final previous = _modPhase >> 16;
      _modPhase = (_modPhase + _modPitch) & 0x3fffff;
      if (_modPhase >> 16 != previous) {
        final step = modulation[previous];
        const deltas = [0, 1, 2, 4, 0, -4, -2, -1];
        _modCounter =
            step == 4 ? 0 : ((_modCounter + deltas[step] + 64) & 127) - 64;
      }
    }
    if (!_waveHalt) {
      var mod = _modCounter * _modGain.gain;
      if (mod & 15 != 0 && mod >= 0) mod += 32;
      final factor = ((mod + 0x400) >> 4) & 255;
      _wavePhase =
          (_wavePhase + ((_pitch * factor) & 0xfffff) ~/ 16) & 0xffffff;
    }
  }

  Float32List synth(int cpuCycles) {
    final output = Float32List(cpuCycles ~/ 2);
    for (var i = 0; i < output.length; i++) {
      _clock();
      _clock();
      final sample = _writeWave
          ? 0.0
          : (wave[_wavePhase >> 18] - 32) /
              32 *
              math.min(32, _volume.gain) /
              32 *
              2 /
              (_masterVolume + 2) *
              0.25;
      _filtered += 0.014 * (sample - _filtered);
      output[i] = _filtered;
    }
    return output;
  }
}
