import 'dart:math';
import 'dart:typed_data';
import '../../../util/int.dart';

/// Sunsoft 5B audio: three square tone channels, a noise generator and an
/// envelope, as on a general purpose sound generator, clocked by the cpu.
///
/// https://www.nesdev.org/wiki/Sunsoft_5B_audio
class Sunsoft5bApu {
  final _reg = Uint8List(16);

  final _tonePeriod = List<int>.filled(3, 1);
  final _toneTimer = List<int>.filled(3, 0);
  final _toneOut = List<bool>.filled(3, false);

  int _noiseTimer = 0;
  int _lfsr = 1;
  bool _noiseOut = false;

  int _envTimer = 0;
  int _envStep = 0; // 0-31
  bool _envHolding = false;
  bool _envAttack = false;

  // 32 levels of 1.5dB; level 0 is silent
  static final _levels = List<double>.generate(
      32, (i) => i == 0 ? 0 : pow(10, -(31 - i) * 1.5 / 20).toDouble());

  void write(int reg, int val) {
    reg &= 0xf;
    _reg[reg] = val;
    switch (reg) {
      case 0 || 1 || 2 || 3 || 4 || 5:
        final ch = reg.shr1;
        _tonePeriod[ch] = _reg[ch * 2] | _reg[ch * 2 + 1].mask4.shl8;
      case 13:
        _envStep = 0;
        _envHolding = false;
        _envAttack = val.bit2;
        _envTimer = 0;
    }
  }

  int get _envLevel => _envAttack ? _envStep : 31 - _envStep;

  void _stepEnvelope() {
    if (_envHolding) return;
    if (++_envStep < 32) return;
    final shape = _reg[13];
    if (!shape.bit3) {
      // the single shapes end silent
      _envStep = 31;
      _envAttack = false;
      _envHolding = true;
      return;
    }
    if (shape.bit0) {
      // hold: an alternating shape holds the other end
      _envStep = 31;
      if (shape.bit1) _envAttack = !_envAttack;
      _envHolding = true;
      return;
    }
    _envStep = 0;
    if (shape.bit1) _envAttack = !_envAttack;
  }

  var buffer = Float32List(0);

  /// generates the output of [cpuCycles], a sample for every 2 cycles
  Float32List exec(int cpuCycles) {
    final samples = cpuCycles ~/ 2;
    if (buffer.length != samples) buffer = Float32List(samples);

    final mixer = _reg[7];
    final noisePeriod = max(_reg[6].mask5, 1);
    final envPeriod = max(_reg[11] | _reg[12].shl8, 1);

    for (var i = 0; i < samples; i++) {
      // the generators count in units of 16 cpu cycles: 8 samples
      for (var ch = 0; ch < 3; ch++) {
        _toneTimer[ch] += 2;
        if (_toneTimer[ch] >= max(_tonePeriod[ch], 1) * 16) {
          _toneTimer[ch] = 0;
          _toneOut[ch] = !_toneOut[ch];
        }
      }
      _noiseTimer += 2;
      if (_noiseTimer >= noisePeriod * 32) {
        _noiseTimer = 0;
        final bit = (_lfsr ^ _lfsr.shr3).mask1;
        _lfsr = _lfsr.shr1 | bit.shl16;
        _noiseOut = _lfsr.bit0;
      }
      _envTimer += 2;
      if (_envTimer >= envPeriod * 16) {
        _envTimer = 0;
        _stepEnvelope();
      }

      var out = 0.0;
      for (var ch = 0; ch < 3; ch++) {
        final tone = mixer & (1 << ch) != 0 || _toneOut[ch];
        final noise = mixer & (8 << ch) != 0 || _noiseOut;
        if (!(tone && noise)) continue;
        final vol = _reg[8 + ch];
        final level = vol.bit4
            ? _envLevel
            : vol.mask4 == 0
                ? 0
                : vol.mask4 * 2 + 1;
        out += _levels[level];
      }
      buffer[i] = out / 3;
    }
    return buffer;
  }

  String dump() => "5b: ${_reg.map((v) => v.toRadixString(16)).join(' ')}";
}
