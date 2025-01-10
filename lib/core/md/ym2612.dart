import 'dart:math';
import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';

// log sin of 0..PI/4, 256 steps, 0x000-0xfff
final logSin256 = List.generate(
    256, (i) => (-log(sin((i + 0.4) * pi / 2 / 256)) * 370).round().toInt());

final exp256 = List.generate(256, (i) => (exp(i / 256) * 1023).toInt());

final incTable = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1,
  0, 1, 0, 1, 0, 1, // 0-3    (0x00-0x03)
  0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1, 1, 1, 0, 1,
  1, 1, 0, 1, 1, 1, // 4-7    (0x04-0x07)
  0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1, 0, 1, 1, 1, 0, 1, 1, 1, 0, 1,
  1, 1, 1, 1, 1, 1, // 8-11   (0x08-0x0B)
  0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1, 0, 1, 1, 1, 0, 1, 1, 1, 0, 1,
  1, 1, 1, 1, 1, 1, // 12-15  (0x0C-0x0F)
  0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1, 0, 1, 1, 1, 0, 1, 1, 1, 0, 1,
  1, 1, 1, 1, 1, 1, // 16-19  (0x10-0x13)
  0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1, 0, 1, 1, 1, 0, 1, 1, 1, 0, 1,
  1, 1, 1, 1, 1, 1, // 20-23  (0x14-0x17)
  0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1, 0, 1, 1, 1, 0, 1, 1, 1, 0, 1,
  1, 1, 1, 1, 1, 1, // 24-27  (0x18-0x1B)
  0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1, 0, 1, 1, 1, 0, 1, 1, 1, 0, 1,
  1, 1, 1, 1, 1, 1, // 28-31  (0x1C-0x1F)
  0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1, 0, 1, 1, 1, 0, 1, 1, 1, 0, 1,
  1, 1, 1, 1, 1, 1, // 32-35  (0x20-0x23)
  0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1, 0, 1, 1, 1, 0, 1, 1, 1, 0, 1,
  1, 1, 1, 1, 1, 1, // 36-39  (0x24-0x27)
  0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1, 0, 1, 1, 1, 0, 1, 1, 1, 0, 1,
  1, 1, 1, 1, 1, 1, // 40-43  (0x28-0x2B)
  0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1, 0, 1, 1, 1, 0, 1, 1, 1, 0, 1,
  1, 1, 1, 1, 1, 1, // 44-47  (0x2C-0x2F)
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2,
  2, 2, 1, 2, 2, 2, // 48-51  (0x30-0x33)
  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 4, 2, 2, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4,
  4, 4, 2, 4, 4, 4, // 52-55  (0x34-0x37)
  4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 8, 4, 4, 4, 8, 4, 8, 4, 8, 4, 8, 4, 8, 4, 8,
  8, 8, 4, 8, 8, 8, // 56-59  (0x38-0x3B)
  8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
  8, 8, 8, 8, 8, 8, // 60-63  (0x3C-0x3F)
];

class Op {
  bool enabled = false;

  int freq = 0;
  int block = 0;

  int _phase = 0; // 0 - 0x1ffff

  int dt = 0;
  int mul = 0;

  int tl = 0; // 00-0x7f
  int ar = 0;
  int rs = 0;
  bool am = false;
  int dr = 0;
  int sr = 0;
  int sl = 0;
  int rr = 0;

  int ssgEg = 0;

  int _level = 0; // final output level of operator, 0-1023
  int _attenuation = 0; // output of EG, 0-1023
  int _rate = 0; // internal increment rate to attenuation
  int _egClockCounter = 0; // clock counter for EG
  int _globalClockCounter = 0; // global counter of FM module
  bool _egInvert = false;

  int _state = 4; // 1:attack, 2:decay, 3:sustain, 4:release
  static const _stateAttack = 1;
  static const _stateDecay = 2;
  static const _stateSustain = 3;
  static const _stateRelease = 4;

  keyOn() {
    _phase = 0;
    _state = _stateAttack;
    _egInvert = true;
    _attenuation = 0;
    _rate = rate(ar);
  }

  keyOff() {
    _state = _stateRelease;
    _egInvert = false;
    _rate = (rr == 0) ? 0 : rate((rr << 1) + 1);
  }

  // ar, dr, sr, rr to rate
  int rate(int r) {
    final result = r == 0 ? 0 : (r << 1) + rs;
    return (result > 63) ? 63 : result;
  }

  // output: -0x10000..0x10000
  int generateOutput(int modulation) {
    final phase = ((modulation + _phase) >> 10) & 0x3ff;
    final qPhase = (phase & 0x100 != 0 ? ~phase : phase) & 0xff;

    final level = (logSin256[qPhase] - (_level << 2)).clip(0, 0x1fff);

    final output = ((exp256[~level & 0xff] | 0x400) << 2) >> (level >> 8);

    return phase & 0x200 != 0 ? -output : output;
  }

  updateEnvelope() {
    switch (_state) {
      case _stateAttack:
        if (_attenuation == 0x3ff) {
          _attenuation = 0;
          _state = _stateDecay;
          _egInvert = false; // TBD: based on ssg-eg inv flag
          _rate = rate(dr);
        }
        break;
      case _stateDecay:
        if ((_level >> 4) == (sr << 1)) {
          _state = _stateSustain;
          _egInvert = false; // TBD: based on ssg-eg inv flag
          _rate = rate(sr);
        }
        break;
      case _stateSustain:
        // TBD: ssg-eg mode repetition / alternate
        break;
      case _stateRelease:
        break;
    }

    final shift = (_rate >= 48) ? 0 : ((47 - _rate) >> 2);
    final inc = incTable[_rate << 3 | (_egClockCounter >> shift & 0x07)];

    if (_state == _stateAttack) {
      _attenuation += inc * (((1024 - _attenuation) >> 4) + 1);
    } else {
      // TBD: inc x 6 in ssg mode
      _attenuation += inc;
    }

    _attenuation = _attenuation.clip(0, 1023);

    final level =
        (tl << 3) + (_egInvert ? ~_attenuation & 0x3ff : _attenuation);
    _level = level.clip(0, 1023);

    _egClockCounter++;
  }

  updatePhase() {
    final lfoFm = 0; // TBD
    final lfoFreq = (freq << 1) + lfoFm;

    final baseFreq = (lfoFreq << block) >> 2;

    final detune = 0; // TBD
    final detuneFreq = baseFreq + detune;

    final inc = (detuneFreq * mul) >> 1;
    _phase = (_phase + (inc & 0xfffff)) & 0xfffff;
  }

  int tick(int modulation) {
    _globalClockCounter += 144;

    updatePhase();

    while (_egClockCounter < _globalClockCounter ~/ 351) {
      _egClockCounter++;
      updateEnvelope();
    }

    return generateOutput(modulation);
  }
}

class Channel {
  final int no;
  Channel(this.no);

  final op = List<Op>.filled(4, Op());

  int freq = 0;
  int block = 0;

  setFreq(bool onlyOp1) {
    if (onlyOp1) {
      op[0].freq = freq;
      op[0].block = block;
      return;
    }

    for (final o in op) {
      o.freq = freq;
      o.block = block;
    }
  }

  int algo = 0;
  int feedback = 0;

  int lfoAms = 0;
  int lfoFms = 0;
  bool lfoEnabled = false;

  bool outLeft = false;
  bool outRight = false;

  int counter = 0;

  var buffer = Float32List(1000);

  var out = 1.0; // pulse wave (temporary)

  int doFeedback(int modulation) {
    return feedback == 0 ? 0 : modulation >> (10 - feedback);
  }

  // 1 sample = 1/44100 sec
  Float32List render(int samples) {
    if (buffer.length != samples) {
      buffer = Float32List(samples);
    }

    for (int i = 0; i < samples; i++) {
      // 0: 1->2->3->4->out
      // 1: 1->3 2->3->4->out
      // 2: 1->4 2->3->4->out
      // 3: 1->2->4->out 3->4->out
      // 4: 1->2->out 3->4->out
      // 5: 1->2->out 1->3->out 1->4->out
      // 6: 1->2->out 3->out 4->out
      // 7: 1->out 2->out 3->out 4->out
      switch (algo) {
        case 0:
          final int op1 = doFeedback(op[0].tick(0));
          final int op2 = op[1].tick(op1);
          final int op3 = op[2].tick(op2 >> 1);
          final int op4 = op[3].tick(op3 >> 1);
          out = op4 / 0x10000;
          break;
        case 1:
          final int op1 = doFeedback(op[0].tick(0));
          final int op2 = op[1].tick(0);
          final int op3 = op[2].tick((op1 + op2) >> 1);
          final int op4 = op[3].tick(op3 >> 1);
          out = op4 / 0x10000;
          break;
        case 2:
          final int op1 = doFeedback(op[0].tick(0));
          final int op2 = op[1].tick(0);
          final int op3 = op[2].tick(op2 >> 1);
          final int op4 = op[3].tick((op1 + op3) >> 1);
          out = op4 / 0x10000;
          break;
        case 3:
          final int op1 = doFeedback(op[0].tick(0));
          final int op2 = op[1].tick(op1);
          final int op3 = op[2].tick(0);
          final int op4 = op[3].tick((op2 + op3) >> 1);
          out = op4 / 0x10000;
          break;
        case 4:
          final int op1 = doFeedback(op[0].tick(0));
          final int op2 = op[1].tick(op1);
          final int op3 = op[2].tick(0);
          final int op4 = op[3].tick(op3 >> 1);
          out = (op2 + op4) / 2 / 0x10000;
          break;
        case 5:
        case 6:
        case 7:
          final int op1 = doFeedback(op[0].tick(0));
          final int op2 = op[1].tick(0);
          final int op3 = op[2].tick(0);
          final int op4 = op[3].tick(0);
          out = (op1 + op2 + op3 + op4) / 4 / 0x10000;
          break;
      }

      buffer[i] = out;
    }

    return buffer;
  }

  int _clip(int val, int min, int max) {
    return val < min
        ? min
        : val > max
            ? max
            : val;
  }
}

class Synth {
  final int part;
  Synth(this.part) : ch = List.generate(3, (i) => Channel(part * 3 + i + 1));

  final List<Channel> ch;

  final ch3freq = List<int>.filled(4, 0);

  int lfoFreq = 0;

  bool isCh3Special = false;
}

class Ym2612 {
  Ym2612();

  var _buffer = Float32List(1000);

  Float32List get audioBuffer => _buffer;

  int timerA = 0; // 18 * (1024 - TIMER A) microseconds, all 0 is the longest
  int timerB = 0; // 288 * (256 - TIMER B ) microseconds, all 0 is the longest

  bool enableTimerA = false;
  bool enableTimerB = false;

  bool enableTimerAOverflow = false;
  bool enableTimerBOverflow = false;

  int timerAOverflow = 0;
  int timerBOverflow = 0;

  int _timerCountA = 0;
  int _timerCountB = 0;

  int dacData = 0;
  bool dacEnabled = false;

  resetTimerA() => _timerCountA = timerA;
  resetTimerB() => _timerCountB = timerB << 4;

  // TIMERA_period = 18 x (1024 -TIMER) microseconds,
  // TIMERB_period = 18 x 16 x (256 -TIMER) microseconds
  // 18ms ~= 1_000_000ms / (m68clock / 144); where m68clock / 144 = 1 sammple
  countTimer(int samples) {
    if (enableTimerA) {
      _timerCountA += samples;
      if (_timerCountA >= 1024) {
        _timerCountA -= 1024 + timerA;
        timerAOverflow = 0x02;
      }
    }

    if (enableTimerB) {
      _timerCountB += samples;
      if (_timerCountB >= 256 * 16) {
        _timerCountB -= 256 * 16 + (timerB << 4);
        timerBOverflow = 0x01;
      }
    }
  }

  final _synth = List.generate(2, (i) => Synth(i));
  final _regs = [0, 0];

  int read8(int part) {
    final status = timerBOverflow | timerAOverflow;
    timerBOverflow = 0;
    timerAOverflow = 0;

    return status;
  }

  writePort8(int part, int value) {
    _regs[part] = value;
  }

  writeData8(int part, int value) {
    final reg = _regs[part];
    final synth = _synth[part];

    switch (reg) {
      case 0x20: // LFO
        synth.lfoFreq = value & 0x07;
        synth.ch[0].lfoEnabled = value.bit3;
        synth.ch[1].lfoEnabled = value.bit2;
        synth.ch[2].lfoEnabled = value.bit1;
        break;

      case 0x24: // Timer A Low
        timerA = timerA & 0x03 | value << 2;
        break;

      case 0x25: // Timer A High
        timerA = timerA & 0x3fc | value & 0x03;
        break;

      case 0x26: // Timer B
        timerB = value;
        break;

      case 0x27: // Timer Control
        synth.isCh3Special = value.bit7;
        if (value.bit5) {
          resetTimerB();
        }
        if (value.bit4) {
          resetTimerA();
        }
        enableTimerBOverflow = value.bit3;
        enableTimerAOverflow = value.bit2;
        enableTimerB = value.bit1;
        enableTimerA = value.bit0;
        break;

      case 0x28: // Operator Control
        final ch = _synth[value >> 2 & 0x01].ch[value & 0x03];

        for (var op = 0; op < 4; op++) {
          value >> (op + 4) & 0x01 == 1
              ? ch.op[op].keyOn()
              : ch.op[op].keyOff();
        }
        break;

      case 0x2a: // dac data
        dacData = value & 0x7f;
        break;

      case 0x2b: // dac control
        dacEnabled = value.bit7;
        return;
    }

    if (0x30 <= reg && reg < 0xa0) {
      final ch = reg & 0x03;
      final op = synth.ch[ch].op[value >> 2 & 0x03];

      final func = reg & 0xf0;

      switch (func) {
        case 0x30: // DT, MUL
          op.dt = value >> 4 & 0x07;
          op.mul = value << 1 & 0x1e;
          if (op.mul == 0) {
            op.mul = 1;
          }
          break;
        case 0x40: // TL
          op.tl = value & 0x7f;
          break;
        case 0x50: // RS(KS), AR
          op.ar = value & 0x0f;
          op.rs = value >> 6 & 0x03;
          break;
        case 0x60: // AM, DR(D1R)
          op.am = value.bit7;
          op.dr = value & 0x1f;
          break;
        case 0x70: // SR(D2R)
          op.sr = value & 0x1f;
          break;
        case 0x80: // SL(D1L), RR
          op.sl = value >> 4 & 0x0f;
          op.rr = value & 0x0f;
          break;
        case 0x90: // SSG-EG
          op.ssgEg = value & 0x0f;
          break;
      }
      return;
    }

    if (0xa0 <= reg && reg < 0xb8) {
      final ch = synth.ch[reg & 0x03];

      if (synth.isCh3Special) {
        switch (reg) {
          case 0xa8: // FNUM
          case 0xa9:
          case 0xaa:
            final op = synth.ch[2].op[reg - 0xa7];
            op.freq = op.freq.setL8(value);
            return;
          case 0xac: // FNUM
          case 0xad:
          case 0xae:
            final op = synth.ch[2].op[reg - 0xac];
            op.freq = op.freq.setH8(value & 0x07);
            op.block = value >> 3 & 0x07;
            return;
        }
      }

      final func = reg & 0xfc;
      switch (func) {
        case 0xa0: // FNUM
          ch.freq = ch.freq.setL8(value);
          ch.setFreq(synth.isCh3Special && ch.no == 3);
          break;
        case 0xa4: // FNUM
          ch.freq = ch.freq.setH8(value & 0x07);
          ch.block = value >> 3 & 0x07;
          break;
        case 0xb0: // FB & ALGO
          ch.feedback = value >> 3 & 0x07;
          ch.algo = value & 0x07;
          break;
        case 0xb4: // L, R and LFO
          ch.outLeft = value.bit7;
          ch.outRight = value.bit6;
          ch.lfoAms = value >> 4 & 0x03;
          ch.lfoFms = value & 0x07;
          break;
      }
      return;
    }
  }

  void reset() {}

  // input:7.670453 MHz / 6 prescale / 4 op / 6 channels = output:53.267 kHz @ ntsc
  static const sampleHz = 53267;

  int elapsedSamples = 0;

  // called 15.720 kHz - DAC should be called more frequently
  Float32List render(int samples) {
    countTimer(samples);

    final buffer = Float32List(samples * 2);

    for (final synth in _synth) {
      for (final ch in synth.ch) {
        if (dacEnabled && ch.no == 6) {
          // mix dac
          for (int i = 0; i < buffer.length; i += 2) {
            buffer[i] += ch.outLeft ? dacData / 256 / 6 : 0;
            buffer[i + 1] += ch.outRight ? dacData / 256 / 6 : 0;
          }

          continue;
        }

        // mix fm
        final out = ch.render(samples);
        for (int i = 0; i < buffer.length; i += 2) {
          buffer[i] += ch.outLeft ? out[i >> 1] / 6 : 0;
          buffer[i + 1] += ch.outRight ? out[i >> 1] / 6 : 0;
        }
      }
    }

    elapsedSamples += samples;

    return buffer;
  }
}
