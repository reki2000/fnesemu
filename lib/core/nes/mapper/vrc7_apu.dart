import 'package:fnesemu/util/int.dart';
// Dart imports:
import 'dart:math';
import 'dart:typed_data';

// https://www.nesdev.org/wiki/VRC7_audio
//
// VRC7 has a reduced YM2413 (OPLL): 6 FM channels, 15 built-in instruments
// + 1 custom instrument, no rhythm mode.
//
// The OPLL generates one sample per 72 master clocks (3.58MHz), which is
// 36 CPU cycles = 18 samples of the APU output buffer (CPU clock / 2).
//
// Attenuations are handled in "EG units" (0.375dB). 16 EG units = 6dB,
// which is a factor of 2, so the log-domain value is `units * 16` where
// 256 means a half of the amplitude.

// built-in instruments by Nuke.YKT (from nesdev wiki)
const _romPatches = [
  [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], // custom
  [0x03, 0x21, 0x05, 0x06, 0xe8, 0x81, 0x42, 0x27], // 1: Buzzy Bell
  [0x13, 0x41, 0x14, 0x0d, 0xd8, 0xf6, 0x23, 0x12], // 2: Guitar
  [0x11, 0x11, 0x08, 0x08, 0xfa, 0xb2, 0x20, 0x12], // 3: Wurly
  [0x31, 0x61, 0x0c, 0x07, 0xa8, 0x64, 0x61, 0x27], // 4: Flute
  [0x32, 0x21, 0x1e, 0x06, 0xe1, 0x76, 0x01, 0x28], // 5: Clarinet
  [0x02, 0x01, 0x06, 0x00, 0xa3, 0xe2, 0xf4, 0xf4], // 6: Synth
  [0x21, 0x61, 0x1d, 0x07, 0x82, 0x81, 0x11, 0x07], // 7: Trumpet
  [0x23, 0x21, 0x22, 0x17, 0xa2, 0x72, 0x01, 0x17], // 8: Organ
  [0x35, 0x11, 0x25, 0x00, 0x40, 0x73, 0x72, 0x01], // 9: Bells
  [0xb5, 0x01, 0x0f, 0x0f, 0xa8, 0xa5, 0x51, 0x02], // A: Vibes
  [0x17, 0xc1, 0x24, 0x07, 0xf8, 0xf8, 0x22, 0x12], // B: Vibraphone
  [0x71, 0x23, 0x11, 0x06, 0x65, 0x74, 0x18, 0x16], // C: Tutti
  [0x01, 0x02, 0xd3, 0x05, 0xc9, 0x95, 0x03, 0x02], // D: Fretless
  [0x61, 0x63, 0x0c, 0x00, 0x94, 0xc0, 0x33, 0xf6], // E: Synth Bass
  [0x21, 0x72, 0x0d, 0x00, 0xc1, 0xd5, 0x56, 0x06], // F: Sweep
];

// multiplier x2 (0 means 0.5)
const _mul2 = [1, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 20, 24, 24, 30, 30];

// key scale level at 6dB/oct in EG units, indexed by upper 4 bits of fnum
const _kslBase = [
  0,
  48,
  64,
  74,
  80,
  86,
  90,
  94,
  96,
  100,
  102,
  104,
  106,
  108,
  110,
  112,
];

// quarter wave of -log2(sin) * 256
final _logSin = List<int>.generate(
  256,
  (i) => (-log(sin((i + 0.5) * pi / 512)) / ln2 * 256).round(),
);

// 2^(-i/256) * 4096
final _exp = List<int>.generate(256, (i) => (pow(2, -i / 256) * 4096).round());

const _egBits = 7;
const _egDpBits = 22;
const _egDpShift = _egDpBits - _egBits;
const _egDpMax = 1 << _egDpBits;
const _egMute = 1 << _egBits;

// exponential attack curve: phase(0..127) -> attenuation(127..0)
final _attackCurve = List<int>.generate(
  _egMute,
  (i) => i == 0
      ? _egMute - 1
      : max(0, (_egMute - 1 - _egMute * log(i) / log(_egMute)).round()),
);

// LFOs, in OPLL samples (49716Hz)
const _amPeriod = 13716; // 3.625Hz
const _amDepth = 13; // 4.875dB in EG units
const _pmPeriod = 8192; // 6.07Hz
const _pmDepth = 0.00797; // 13.75 cents

class _OpParam {
  bool am = false;
  bool pm = false;
  bool egSustained = false;
  bool ksr = false;
  int mul = 0;
  int ksl = 0;
  int tl = 0; // modulator only
  bool rectify = false;
  int ar = 0;
  int dr = 0;
  int sl = 0;
  int rr = 0;
}

class _Patch {
  final mod = _OpParam();
  final car = _OpParam();
  int fb = 0;

  _Patch(List<int> r) {
    set(r);
  }

  void set(List<int> r) {
    for (final (op, i) in [(mod, 0), (car, 1)]) {
      op.am = r[i].bit7;
      op.pm = r[i].bit6;
      op.egSustained = r[i].bit5;
      op.ksr = r[i].bit4;
      op.mul = r[i] & 0x0f;
      op.ksl = r[2 + i].shr6;
      op.ar = r[4 + i].shr4;
      op.dr = r[4 + i] & 0x0f;
      op.sl = r[6 + i].shr4;
      op.rr = r[6 + i] & 0x0f;
    }
    mod.tl = r[2] & 0x3f;
    car.rectify = r[3].bit4;
    mod.rectify = r[3].bit3;
    fb = r[3] & 0x07;
  }
}

enum _EgState { attack, decay, sustainHold, sustain, release, finished }

class _Slot {
  int phase = 0; // 19 bits, upper 10 bits are the wave index
  _EgState state = _EgState.finished;
  int egPhase = _egDpMax;

  void keyOn(_OpParam p) {
    phase = 0;
    egPhase = 0;
    state = _EgState.attack;
    if (p.ar == 15) {
      state = _EgState.decay;
    }
  }

  void keyOff() {
    if (state != _EgState.finished) {
      if (state == _EgState.attack) {
        egPhase = _attackCurve[egPhase >> _egDpShift] << _egDpShift;
      }
      state = _EgState.release;
    }
  }

  static int _decayInc(int rate, int rks) {
    if (rate == 0) return 0;
    final rm = min(15, rate + rks.shr2);
    return ((rks & 3) + 4) << (rm - 1);
  }

  static int _attackInc(int rate, int rks) {
    if (rate == 0) return 0;
    final rm = min(15, rate + rks.shr2);
    return (3 * ((rks & 3) + 4)) << (rm + 1);
  }

  /// advances the envelope and returns its attenuation in EG units
  int calcEg(_OpParam p, int rks, bool susOn) {
    switch (state) {
      case _EgState.attack:
        egPhase += _attackInc(p.ar, rks);
        if (egPhase >= _egDpMax) {
          egPhase = 0;
          state = _EgState.decay;
        } else {
          return _attackCurve[egPhase >> _egDpShift];
        }
        break;

      case _EgState.decay:
        egPhase += _decayInc(p.dr, rks);
        final sl = (p.sl * 8) << _egDpShift; // 3dB steps
        if (egPhase >= sl) {
          egPhase = sl;
          state = p.egSustained ? _EgState.sustainHold : _EgState.sustain;
        }
        break;

      case _EgState.sustainHold:
        break;

      case _EgState.sustain:
        egPhase += _decayInc(p.rr, rks);
        break;

      case _EgState.release:
        final rate = susOn ? 5 : (p.egSustained ? p.rr : 7);
        egPhase += _decayInc(rate, rks);
        break;

      case _EgState.finished:
        return _egMute;
    }

    if (egPhase >= _egDpMax) {
      egPhase = _egDpMax;
      state = _EgState.finished;
      return _egMute;
    }

    return egPhase >> _egDpShift;
  }
}

class _Channel {
  int fnum = 0; // 9 bits
  int block = 0; // 3 bits
  bool key = false;
  bool susOn = false;
  int inst = 0;
  int vol = 0;

  final mod = _Slot();
  final car = _Slot();

  // last two modulator outputs for feedback
  int fb1 = 0;
  int fb2 = 0;

  int output = 0;
}

/// Emulates VRC7 audio (YM2413 subset)
class Vrc7Apu {
  final _patches = _romPatches.map((r) => _Patch(r)).toList();
  final _custom = Uint8List(8);

  final _ch = List.generate(6, (_) => _Channel());

  int _addr = 0;
  bool mute = false;

  int _amCounter = 0;
  int _pmCounter = 0;

  // remaining APU buffer samples to hold the current OPLL sample
  static const _apuSamplesPerOpllSample = 18;
  int _holdCount = 0;
  double _lastSample = 0;

  void reset() {
    for (final c in _ch) {
      c.key = false;
      c.mod.state = _EgState.finished;
      c.car.state = _EgState.finished;
    }
  }

  void selectReg(int val) {
    _addr = val & 0xff;
  }

  void write(int val) {
    final reg = _addr;

    if (reg < 0x08) {
      _custom[reg] = val;
      _patches[0].set(_custom);
      return;
    }

    final n = reg & 0x0f;
    if (n >= 6) {
      return;
    }
    final c = _ch[n];

    switch (reg & 0xf0) {
      case 0x10:
        c.fnum = c.fnum & 0x100 | val;
        break;

      case 0x20:
        c.fnum = (val & 0x01) << 8 | c.fnum & 0xff;
        c.block = (val >> 1) & 0x07;
        c.susOn = val.bit5;

        final key = val.bit4;
        if (key && !c.key) {
          final p = _patches[c.inst];
          c.mod.keyOn(p.mod);
          c.car.keyOn(p.car);
        } else if (!key && c.key) {
          c.car.keyOff();
        }
        c.key = key;
        break;

      case 0x30:
        c.inst = val.shr4;
        c.vol = val & 0x0f;
        break;
    }
  }

  // returns the output of the operator in -4096..4096
  static int _wave(int index, int att, bool rectify) {
    final i = index & 0x3ff;
    final q = i & 0x100 != 0 ? 0xff - (i & 0xff) : i & 0xff;
    final negative = i & 0x200 != 0;

    if (negative && rectify) {
      return 0;
    }

    final level = _logSin[q] + att * 16;
    final shift = level >> 8;
    if (shift >= 13) {
      return 0;
    }

    final out = _exp[level & 0xff] >> shift;
    return negative ? -out : out;
  }

  static int _ksl(int ksl, int fnum, int block) {
    if (ksl == 0) {
      return 0;
    }
    final base = _kslBase[fnum >> 5] - 16 * (7 - block);
    if (base <= 0) {
      return 0;
    }
    return base >> (3 - ksl);
  }

  int _phaseInc(_OpParam p, _Channel c, double pm) {
    final inc = ((c.fnum * _mul2[p.mul]) << c.block) >> 1;
    return p.pm ? (inc * (1 + pm)).toInt() : inc;
  }

  // generates one OPLL sample
  double _synth() {
    // LFOs
    _amCounter = (_amCounter + 1) % _amPeriod;
    _pmCounter = (_pmCounter + 1) % _pmPeriod;
    final amTri = _amCounter < _amPeriod ~/ 2
        ? _amCounter
        : _amPeriod - _amCounter; // 0 .. amPeriod/2
    final am = amTri * _amDepth * 2 ~/ _amPeriod;
    final pm = sin(2 * pi * _pmCounter / _pmPeriod) * _pmDepth;

    int sum = 0;

    for (final c in _ch) {
      final p = _patches[c.inst];

      // key scale rate
      final rksBase = c.block << 1 | c.fnum >> 8;

      // modulator
      final mp = p.mod;
      final modEg = c.mod.calcEg(mp, mp.ksr ? rksBase : rksBase.shr2, false);
      c.mod.phase = (c.mod.phase + _phaseInc(mp, c, pm)) & 0x7ffff;

      int modOut = 0;
      if (modEg < _egMute) {
        final fb = p.fb == 0 ? 0 : (c.fb1 + c.fb2) >> (9 - p.fb);
        final att =
            modEg +
            mp.tl * 2 +
            _ksl(mp.ksl, c.fnum, c.block) +
            (mp.am ? am : 0);
        modOut = _wave((c.mod.phase >> 9) + fb, att, mp.rectify);
      }
      c.fb2 = c.fb1;
      c.fb1 = modOut;

      // carrier
      final cp = p.car;
      final carEg = c.car.calcEg(cp, cp.ksr ? rksBase : rksBase.shr2, c.susOn);
      c.car.phase = (c.car.phase + _phaseInc(cp, c, pm)) & 0x7ffff;

      int out = 0;
      if (carEg < _egMute) {
        final att =
            carEg +
            c.vol * 8 +
            _ksl(cp.ksl, c.fnum, c.block) +
            (cp.am ? am : 0);
        out = _wave((c.car.phase >> 9) + modOut, att, cp.rectify);
      }
      c.output = out;
      sum += out;
    }

    // a channel at full volume is about as loud as a square wave of the APU
    return sum / 4096 * 0.25;
  }

  var buffer = Float32List(0);

  /// Generates output for the specified CPU cycles at the APU sample rate
  Float32List exec(int cpuCycles) {
    final cycles = cpuCycles ~/ 2;

    if (buffer.length != cycles) {
      buffer = Float32List(cycles);
    }

    for (int i = 0; i < cycles; i++) {
      if (_holdCount <= 0) {
        _lastSample = _synth();
        _holdCount = _apuSamplesPerOpllSample;
      }
      _holdCount--;
      buffer[i] = mute ? 0 : _lastSample;
    }

    return buffer;
  }

  String dump() {
    return _ch
        .map(
          (c) =>
              "${c.inst.hex}${c.key ? '*' : '-'}"
              "${c.block}:${c.fnum.toRadixString(16).padLeft(3, '0')}"
              "v${c.vol.hex}${c.car.state.name[0]}",
        )
        .join(" ");
  }
}
