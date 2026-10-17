import 'dart:math';
import 'dart:typed_data';

/// YM2413 (OPLL): 9 channels of 2-operator FM, or 6 channels and 5 rhythm
/// sounds.
///
/// Written from the datasheet and its application manual: the register map,
/// the multiples, the key scale tables, the envelope times (table III-7) and
/// the modulation indices. The built-in instruments are the values measured
/// by the openMSX YM2413 reverse engineering project (ym2413-instr.ods).
class Opll {
  /// the output sample rate
  final int sampleRate;

  Opll({this.sampleRate = 3579545 ~/ 72});

  final regs = Uint8List(0x40);
  int _address = 0;

  final _channels = List.generate(9, (_) => _Channel());

  double _amPhase = 0, _vibPhase = 0;
  int _noise = 1;

  void reset() {
    regs.fillRange(0, regs.length, 0);
    _address = 0;
    for (final ch in _channels) {
      ch.reset();
    }
    _amPhase = _vibPhase = 0;
    _noise = 1;
  }

  void writeAddress(int value) => _address = value & 0x3f;

  void writeData(int value) {
    final addr = _address;
    final old = regs[addr];
    regs[addr] = value;
    if (addr >= 0x20 && addr <= 0x28) {
      final ch = _channels[addr - 0x20];
      final keyOn = value & 0x10 != 0, wasOn = old & 0x10 != 0;
      if (keyOn && !wasOn) ch.keyOn();
      if (!keyOn && wasOn) ch.keyOff();
    } else if (addr == 0x0e) {
      // the rhythm keys: bd(4) sd(3) tom(2) cym(1) hh(0)
      void key(_Operator op, int bit) {
        final on = value >> bit & 1 != 0, was = old >> bit & 1 != 0;
        if (on && !was) op.keyOn();
        if (!on && was) op.keyOff();
      }

      key(_channels[6].mod, 4);
      key(_channels[6].car, 4);
      key(_channels[7].car, 3);
      key(_channels[8].mod, 2);
      key(_channels[8].car, 1);
      key(_channels[7].mod, 0);
    }
  }

  bool get _rhythm => regs[0x0e] & 0x20 != 0;

  // the instrument bytes, in the layout of the user tone registers 0-7
  Uint8List _patch(int no) =>
      no == 0 ? Uint8List.sublistView(regs, 0, 8) : _rom[no];

  /// renders [samples] samples into [out] from [offset]
  void renderTo(Float32List out, int offset, int samples) {
    final dt = 1 / sampleRate;
    for (var i = 0; i < samples; i++) {
      // AM 3.7Hz with a 4.8dB depth, vibrato 6.4Hz with a 14 cent depth
      _amPhase = (_amPhase + 3.7 * dt) % 1;
      _vibPhase = (_vibPhase + 6.4 * dt) % 1;
      final am = (1 - cos(2 * pi * _amPhase)) / 2 * 4.8;
      final vib = pow(2, sin(2 * pi * _vibPhase) * 14 / 1200).toDouble();
      _noise = (_noise >> 1) | ((_noise ^ _noise >> 14) & 1) << 22;

      var sum = 0.0;
      final rhythm = _rhythm;
      for (var c = 0; c < 9; c++) {
        if (rhythm && c >= 6) continue;
        sum += _melody(c, am, vib, dt);
      }
      if (rhythm) sum += _rhythmOut(am, vib, dt) * 2;
      out[offset + i] = sum / 9;
    }
  }

  int _fnum(int c) => regs[0x10 + c] | (regs[0x20 + c] & 1) << 8;
  int _block(int c) => regs[0x20 + c] >> 1 & 7;

  double _melody(int c, double am, double vib, double dt) {
    final ch = _channels[c];
    final patch = _patch(regs[0x30 + c] >> 4);
    final fnum = _fnum(c), block = _block(c);
    final sustain = regs[0x20 + c] & 0x20 != 0;
    final volume = (regs[0x30 + c] & 15) * 3.0;

    final m = ch.mod
      ..configure(patch, 0, fnum, block, sustain, am, vib, dt)
      ..totalLevel = (patch[2] & 0x3f) * 0.75;
    final cr = ch.car
      ..configure(patch, 1, fnum, block, sustain, am, vib, dt)
      ..totalLevel = volume;

    final fb = patch[3] & 7;
    final feedback = fb == 0 ? 0.0 : pi / 16 * (1 << (fb - 1)) * m.last;
    final mod = m.output(feedback);
    return cr.output(mod * 4 * pi);
  }

  double _rhythmOut(double am, double vib, double dt) {
    final s6 = regs[0x26] & 0x20 != 0;
    var sum = 0.0;

    // bass drum: a normal 2-operator voice on channel 6
    final bd = _channels[6];
    bd.mod
      ..configure(_rom[16], 0, _fnum(6), _block(6), s6, am, vib, dt)
      ..totalLevel = (_rom[16][2] & 0x3f) * 0.75;
    bd.car
      ..configure(_rom[16], 1, _fnum(6), _block(6), s6, am, vib, dt)
      ..totalLevel = (regs[0x36] & 15) * 3.0;
    final fb = _rom[16][3] & 7;
    final bdMod =
        bd.mod.output(fb == 0 ? 0 : pi / 16 * (1 << (fb - 1)) * bd.mod.last);
    sum += bd.car.output(bdMod * 4 * pi);

    final noise = _noise & 1 != 0 ? 1.0 : -1.0;
    final s7 = regs[0x27] & 0x20 != 0, s8 = regs[0x28] & 0x20 != 0;

    // high hat (channel 7 modulator) and snare drum (channel 7 carrier)
    final hh = _channels[7].mod
      ..configure(_rom[17], 0, _fnum(7), _block(7), s7, am, vib, dt)
      ..totalLevel = (regs[0x37] >> 4) * 3.0;
    final sd = _channels[7].car
      ..configure(_rom[17], 1, _fnum(7), _block(7), s7, am, vib, dt)
      ..totalLevel = (regs[0x37] & 15) * 3.0;
    sum += hh.noiseOutput(noise, 0.75);
    sum += sd.noiseOutput(noise, 0.5);

    // tom-tom (channel 8 modulator) and top cymbal (channel 8 carrier)
    final tom = _channels[8].mod
      ..configure(_rom[18], 0, _fnum(8), _block(8), s8, am, vib, dt)
      ..totalLevel = (regs[0x38] >> 4) * 3.0;
    final cym = _channels[8].car
      ..configure(_rom[18], 1, _fnum(8), _block(8), s8, am, vib, dt)
      ..totalLevel = (regs[0x38] & 15) * 3.0;
    sum += tom.output(0);
    sum += cym.noiseOutput(noise, 0.25);
    return sum;
  }

  // the measured instruments 1-15 and the rhythm sounds 16-18 (bd, hh/sd,
  // tom/cym), as the bytes of the user tone registers 0-7
  static final _rom = [
    Uint8List(8),
    for (final hex in _instruments)
      Uint8List.fromList(
          [for (final b in hex.split(' ')) int.parse(b, radix: 16)]),
  ];

  static const _instruments = [
    '61 61 1e 17 f0 7f 00 17', // violin
    '13 41 16 0e fd f4 23 23', // guitar
    '03 01 9a 04 f3 f3 13 f3', // piano
    '11 61 0e 07 fa 64 70 17', // flute
    '22 21 1e 06 f0 76 00 28', // clarinet
    '21 22 16 05 f0 71 00 18', // oboe
    '21 61 1d 07 82 80 17 17', // trumpet
    '23 21 2d 16 90 90 00 07', // organ
    '21 21 1b 06 64 65 10 17', // horn
    '21 21 0b 1a 85 a0 70 07', // synthesizer
    '23 01 83 10 ff b4 10 f4', // harpsichord
    '97 c1 20 07 ff f4 22 22', // vibraphone
    '61 00 0c 05 c2 f6 40 44', // synthesizer bass
    '01 01 56 03 94 c2 03 12', // acoustic bass
    '21 01 89 03 f1 e4 f0 23', // electric guitar
    '07 21 14 00 ee f8 ff f8', // bd
    '01 31 00 00 f8 f7 f8 f7', // hh/sd
    '25 11 00 00 f8 fa f8 55', // tom/cym
  ];
}

class _Channel {
  final mod = _Operator(), car = _Operator();

  void reset() {
    mod.reset();
    car.reset();
  }

  void keyOn() {
    mod.keyOn();
    car.keyOn();
  }

  void keyOff() {
    mod.keyOff();
    car.keyOff();
  }
}

enum _Stage { damp, attack, decay, sustain, release }

class _Operator {
  // the attenuation of the envelope in dB, 0 to 48
  double _env = 48;
  _Stage _stage = _Stage.release;
  double _phase = 0;
  double last = 0;

  // the parameters of the current sample
  double _inc = 0, _attenuation = 0;
  bool _sustained = false, _rectify = false, _susOn = false;
  int _ar = 0, _dr = 0, _rr = 0, _keyScale = 0;
  double _sl = 0;
  double _dt = 0;
  double totalLevel = 0;

  static const _multiples = [
    0.5, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 10, 12, 12, 15, 15 //
  ];

  // the key scale level at 3dB/octave of block 7 for the top 4 bits of the
  // F-number: application manual table III-5
  static const _kslTable = [
    0, 9, 12, 13.875, 15, 16.125, 16.875, 17.625, //
    18, 18.75, 19.125, 19.5, 19.875, 20.25, 20.625, 21
  ];

  void reset() {
    _env = 48;
    _stage = _Stage.release;
    _phase = 0;
    last = 0;
  }

  void keyOn() {
    _stage = _env < 48 ? _Stage.damp : _Stage.attack;
    _phase = 0;
  }

  void keyOff() {
    if (_stage != _Stage.release) _stage = _Stage.release;
  }

  void configure(Uint8List patch, int op, int fnum, int block, bool susOn,
      double am, double vib, double dt) {
    final reg0 = patch[op];
    _dt = dt;
    _susOn = susOn;
    _sustained = reg0 & 0x20 != 0;
    _rectify = patch[3] >> (op == 0 ? 3 : 4) & 1 != 0;

    // phase increment: 2^18 per cycle at fM / 72, F * 2^(block - 1) * MUL
    final freq = fnum *
        (1 << block) /
        2 *
        _multiples[reg0 & 15] *
        (3579545 / 72) /
        (1 << 18);
    _inc = freq * (reg0 & 0x40 != 0 ? vib : 1) * dt;

    // rate key scale: (block, F-number MSB) with or without the 2 bit shift
    final ks = block << 1 | fnum >> 8;
    _keyScale = reg0 & 0x10 != 0 ? ks : ks >> 2;

    final ad = patch[4 + op], sr = patch[6 + op];
    _ar = ad >> 4;
    _dr = ad & 15;
    _sl = (sr >> 4) * 3.0;
    _rr = sr & 15;

    // key scale level: 0, 3, 1.5 or 6 dB/octave for the field 0-3
    final kslField = patch[2 + op] >> 6;
    final ksl = max(0.0, _kslTable[fnum >> 5] - 3.0 * (7 - block));
    final kslScale = const [0.0, 1.0, 0.5, 2.0][kslField];
    _attenuation = ksl * kslScale + (reg0 & 0x80 != 0 ? am : 0);
  }

  // the time in seconds to change 48dB at the rate: table III-7
  static double _decayTime(int rate) {
    if (rate >= 60) return 1.27e-3;
    final rm = rate >> 2, rl = rate & 3;
    return 20.92666 / (1 << (rm - 1)) * 4 / (4 + rl);
  }

  static double _attackTime(int rate) =>
      1.73015 / (1 << ((rate >> 2) - 1)) * 4 / (4 + (rate & 3));

  int _rate(int r) => r == 0 ? 0 : min(63, r * 4 + _keyScale);

  double _decayStep(int r) {
    final rate = _rate(r);
    return rate == 0 ? 0 : 48 / _decayTime(rate) * _dt;
  }

  void _envelope() {
    switch (_stage) {
      case _Stage.damp:
        // quickly fades the previous sound before the attack: ~10ms
        _env += 48 / 0.01 * _dt;
        if (_env >= 48) {
          _env = 48;
          _stage = _Stage.attack;
        }
      case _Stage.attack:
        final rate = _rate(_ar);
        if (rate >= 60) {
          _env = 0;
        } else if (rate > 0) {
          // exponential in dB: the amplitude rises over the attack time
          final amp = pow(10, -_env / 20) + _dt / _attackTime(rate);
          _env = amp >= 1 ? 0 : -20 * log(amp) / ln10;
        }
        if (_env <= 0) {
          _env = 0;
          _stage = _Stage.decay;
        }
      case _Stage.decay:
        _env += _decayStep(_dr);
        if (_env >= _sl) {
          _env = _sl;
          _stage = _Stage.sustain;
        }
      case _Stage.sustain:
        // percussive tones keep decaying with the release rate
        if (!_sustained) _env += _decayStep(_rr);
      case _Stage.release:
        // the sustain bit of the channel slows the release to the rate 5
        _env += _decayStep(_susOn ? 5 : _rr);
    }
    if (_env > 48) _env = 48;
  }

  double get _amplitude {
    final db = _env + totalLevel + _attenuation;
    return db >= 48 ? 0 : pow(10, -db / 20).toDouble();
  }

  /// the next sample with the phase modulation [mod] in radians
  double output(double mod) {
    _envelope();
    _phase = (_phase + _inc) % 1;
    var v = sin(2 * pi * _phase + mod);
    if (_rectify && v < 0) v = 0;
    last = v * _amplitude;
    return last;
  }

  /// the next sample of a noise based rhythm sound
  double noiseOutput(double noise, double tone) {
    _envelope();
    _phase = (_phase + _inc) % 1;
    final square = _phase < 0.5 ? 1.0 : -1.0;
    last = (square * tone + noise * (1 - tone)) * _amplitude;
    return last;
  }
}
