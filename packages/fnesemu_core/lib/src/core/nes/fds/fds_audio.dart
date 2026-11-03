import 'dart:math' as math;
import 'dart:typed_data';
import '../../../util/int.dart';
import '../../../util/state.dart';

class _Envelope {
  int control = 0x80, gain = 0, timer = 0;

  void saveState(StateWriter w) {
    w.ints([control, gain, timer]);
  }

  void loadState(StateReader s) {
    final v = s.ints();
    if (v.length != 3) throw const StateMismatch('fds envelope state layout');
    control = v[0];
    gain = v[1];
    timer = v[2];
  }
  void write(int value) {
    control = value;
    timer = 0;
    if (value.bit7) gain = value.mask6;
  }

  void tick(int masterSpeed) {
    if (control.bit7) return;
    timer++;
    final period = 8 * (control.mask6 + 1) * (masterSpeed + 1);
    if (timer < period) return;
    timer = 0;
    if (control.bit6) {
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

  /// Saves the wave and modulation tables, both envelopes and the phase and counter state.
  void saveState(StateWriter w) {
    w.section('fds-audio');
    w.bytes(wave);
    w.bytes(modulation);
    _volume.saveState(w);
    _modGain.saveState(w);
    w.ints([_pitch, _modPitch, _wavePhase, _modPhase, _modCounter, _masterSpeed, _masterVolume]);
    w.boolean(_waveHalt);
    w.boolean(_modHalt);
    w.boolean(_envelopeHalt);
    w.boolean(_writeWave);
    w.float64(_filtered);
  }

  /// Restores the state written by [saveState].
  void loadState(StateReader s) {
    s.section('fds-audio');
    s.bytesInto(wave);
    s.bytesInto(modulation);
    _volume.loadState(s);
    _modGain.loadState(s);
    final v = s.ints();
    if (v.length != 7) throw const StateMismatch('fds audio state layout');
    _pitch = v[0];
    _modPitch = v[1];
    _wavePhase = v[2];
    _modPhase = v[3];
    _modCounter = v[4];
    _masterSpeed = v[5];
    _masterVolume = v[6];
    _waveHalt = s.boolean();
    _modHalt = s.boolean();
    _envelopeHalt = s.boolean();
    _writeWave = s.boolean();
    _filtered = s.float64();
  }

  int read(int address) {
    if (address >= 0x4040 && address <= 0x407f) {
      return wave[_writeWave ? address.mask6 : _wavePhase.shr18];
    }
    return switch (address) {
      0x4090 => 0x40 | _volume.gain,
      0x4092 => 0x40 | _modGain.gain,
      _ => 0xff,
    };
  }

  void write(int address, int value) {
    if (address >= 0x4040 && address <= 0x407f) {
      if (_writeWave) wave[address.mask6] = value.mask6;
      return;
    }
    switch (address) {
      case 0x4080:
        _volume.write(value);
      case 0x4082:
        _pitch = (_pitch & 0xf00) | value;
      case 0x4083:
        _pitch = _pitch.mask8 | value.mask4.shl8;
        _waveHalt = value.bit7;
        _envelopeHalt = value.bit6;
        if (_waveHalt) _wavePhase = 0;
        if (_envelopeHalt) _volume.timer = _modGain.timer = 0;
      case 0x4084:
        _modGain.write(value);
      case 0x4085:
        _modCounter = (value + 64).mask7 - 64;
      case 0x4086:
        _modPitch = (_modPitch & 0xf00) | value;
      case 0x4087:
        _modPitch = _modPitch.mask8 | value.mask4.shl8;
        _modHalt = value.bit7;
        if (_modHalt) _modPhase &= ~0xffff;
      case 0x4088:
        if (_modHalt) {
          final index = _modPhase.shr16;
          modulation[index] = modulation[(index + 1).mask6] = value.mask3;
          _modPhase = (_modPhase + (2 << 16)) & 0x3fffff;
        }
      case 0x4089:
        _writeWave = value.bit7;
        _masterVolume = value.mask2;
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
      final previous = _modPhase.shr16;
      _modPhase = (_modPhase + _modPitch) & 0x3fffff;
      if (_modPhase.shr16 != previous) {
        final step = modulation[previous];
        const deltas = [0, 1, 2, 4, 0, -4, -2, -1];
        _modCounter =
            step == 4 ? 0 : (_modCounter + deltas[step] + 64).mask7 - 64;
      }
    }
    if (!_waveHalt) {
      var mod = _modCounter * _modGain.gain;
      if (mod.mask4 != 0 && mod >= 0) mod += 32;
      final factor = (mod + 0x400).shr4.mask8;
      _wavePhase = (_wavePhase + ((_pitch * factor) & 0xfffff) ~/ 16).mask24;
    }
  }

  Float32List synth(int cpuCycles) {
    final output = Float32List(cpuCycles ~/ 2);
    for (var i = 0; i < output.length; i++) {
      _clock();
      _clock();
      final sample = _writeWave
          ? 0.0
          : (wave[_wavePhase.shr18] - 32) /
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
