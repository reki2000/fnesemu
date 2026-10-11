import 'dart:math';
import 'dart:typed_data';

import '../../util/int.dart';

// Lots of helpful hints from this thread:
//   https://gendev.spritesmind.net/forum/viewtopic.php?t=386&start=105
// also:
//   https://github.com/nukeykt/Nuked-OPN2/blob/master/ym3438.c

// log sin of 0..PI/4, 256 steps: 0x000-0xfff
final _logSinTable = Int32List.fromList(List.generate(
    256, (i) => (-log(sin((i + 0.4) * pi / 2 / 256)) * 370).round().toInt()));

// exp of e^0..e^1, 256 steps, -1 biased: 0x3ff-0x000
final _expTable = Int32List.fromList(List.generate(
    256, (i) => ((exp(i / 256) - 1.0) / (exp(1) - 1.0) * 1023).toInt()));

final _attenuateIncTable = Int32List.fromList([
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
]);

final _detuneTable = [
  0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, //  dt=1, keyCode 0..1f
  2, 3, 3, 3, 4, 4, 4, 5, 5, 6, 6, 7, 8, 8, 8, 8, //
  1, 1, 1, 1, 2, 2, 2, 2, 2, 3, 3, 3, 4, 4, 4, 5, // dt=2
  5, 6, 6, 7, 8, 8, 9, 10, 11, 12, 13, 14, 16, 16, 16, 16, //
  2, 2, 2, 2, 2, 3, 3, 3, 4, 4, 4, 5, 5, 6, 6, 7, // dt=3
  8, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 20, 22, 22, 22, 22 //
];

final _lfoFms1Table = [
  [7, 7, 7, 7, 7, 7, 7, 7], //
  [7, 7, 7, 7, 7, 7, 7, 7], //
  [7, 7, 7, 7, 7, 7, 1, 1], //
  [7, 7, 7, 7, 1, 1, 1, 1], //
  [7, 7, 7, 1, 1, 1, 1, 0], //
  [7, 7, 1, 1, 0, 0, 0, 0], //
  [7, 7, 1, 1, 0, 0, 0, 0], //
  [7, 7, 1, 1, 0, 0, 0, 0], //
];

final _lfoFms2Table = [
  [7, 7, 7, 7, 7, 7, 7, 7], //
  [7, 7, 7, 7, 2, 2, 2, 2], //
  [7, 7, 7, 2, 2, 2, 7, 7], //
  [7, 7, 2, 2, 7, 7, 2, 2], //
  [7, 7, 2, 7, 7, 7, 2, 7], //
  [7, 7, 7, 2, 7, 7, 2, 1], //
  [7, 7, 7, 2, 7, 7, 2, 1], //
  [7, 7, 7, 2, 7, 7, 2, 1], //
];

final _keyCodeTable = [0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 3, 3, 3, 3, 3, 3]; //

class Op {
  final Channel ch;
  final String no;
  Op(this.ch, int no) : no = "${ch.no}-$no";

  static const outBits = 13; // not include 1 bit for sign
  static const outSize = 1 << outBits;
  static const outMask = outSize - 1;

  static const egAttenuationBits = 10;
  static const egAttenuationSize = 1 << egAttenuationBits;
  static const egAttenuationMask = egAttenuationSize - 1;

  int freq = 0; // 0-0x7ff
  int block = 0; // 0-7
  int _keyCode = 0;
  set keyCode(int value) => setDetuneAndKeyCode(_dt, value);

  int _detuneVal = 0; // pre-calculated detune value

  int _dt = 0;
  set dt(int value) => setDetuneAndKeyCode(value, _keyCode);

  setDetuneAndKeyCode(int dt, int keyCode) {
    _dt = dt;
    _keyCode = keyCode;
    final detune =
        dt.mask2 == 0 ? 0 : _detuneTable[(dt.mask2 - 1).shl5 | keyCode];
    _detuneVal = dt.bit2 ? detune : -detune;
  }

  int mul = 0; // 1,2,4,..30 (0.5 ,1,2...15 with 1 right shift)

  int tl = 0; // 00-0x7f
  int ar = 0;
  int rs = 0;
  bool am = false;
  int dr = 0;
  int sr = 0;
  int sl = 0;
  int rr = 0;

  int ssgEg = 0;

  int _phase = 0; // 24bit: 0 - 0xfffff

  int _egLevel = 0x3ff; // final output level of operator, 0(loud) - 1023(quiet)
  int _egAttenuation = 0; // output of EG, 0(loud) - 1023(quiet)
  int _egRate = 0; // internal increment rate for the attenuation
  bool _egInvert = false;

  static const _egStateAttack = 0;
  static const _egStateDecay = 1;
  static const _egStateSustain = 2;
  static const _egStateRelease = 3;
  int _egState = _egStateRelease;

  bool _keyed = false;

  keyOn({bool retrigger = false}) {
    if (_keyed && !retrigger) {
      return;
    }
    _keyed = true;

    _phase = 0;
    _egState = _egStateAttack;
    _egInvert = true;
    _egAttenuation = 0;
    _egRate = rate(ar);
    // if (ar != 0) {
    //   print(
    //       "op$no ph:${_phase.x6} state:$_state rate:${_rate.x2} atten:${_attenuation.x4} lv:${_level.x4}");
    // }
  }

  keyOff() {
    if (!_keyed) {
      return;
    }
    _keyed = false;

    _egState = _egStateRelease;
    _egInvert = false;
    _egRate = (rr == 0) ? 0 : rate(rr.shl1 + 1);
  }

  // ar, dr, sr, rr to rate
  int rate(int r) {
    final result = r == 0 ? 0 : (r.shl1 + (_keyCode >> (3 - rs)));
    return (result > 63) ? 63 : result;
  }

  updateEnvelope() {
    switch (_egState) {
      case _egStateAttack:
        if (_egAttenuation == egAttenuationMask) {
          _egAttenuation = 0;
          _egState = _egStateDecay;
          _egInvert = false; // TBD: based on ssg-eg inv flag
          _egRate = rate(dr);
        }
        break;
      case _egStateDecay:
        if (_egAttenuation.shr4 == sl.shl1) {
          _egState = _egStateSustain;
          _egInvert = false; // TBD: based on ssg-eg inv flag
          _egRate = rate(sr);
        }
        break;
      case _egStateSustain:
        // TBD: ssg-eg mode repetition / alternate
        break;
      case _egStateRelease:
        break;
    }

    final shift = (_egRate >= 44) ? 0 : (11 - _egRate.shr2);

    // if (no == "1-4") {
    //   print(
    //       "op$no state:$_state counter:$egClockCounter rate:$_rate shift:$shift inc:${incTable[_rate << 3 | egClockCounter >> shift & 0x07]} atten:$_attenuation lv:$_level");
    // }

    if (shift == 0 || ch.egClockCounter & ((1 << shift) - 1) == 0) {
      final inc =
          _attenuateIncTable[_egRate.shl3 | (ch.egClockCounter >> shift).mask3];

      if (_egState == _egStateAttack) {
        _egAttenuation += inc * ((egAttenuationSize - _egAttenuation).shr4 + 1);
      } else {
        // TBD: inc x 6 in ssg mode
        _egAttenuation += inc;
      }

      _egAttenuation = _egAttenuation.clip(0, egAttenuationMask);

      final level = tl.shl3 +
          (_egInvert ? (~_egAttenuation) & egAttenuationMask : _egAttenuation);
      _egLevel = level.clip(0, egAttenuationMask);
    }
  }

  updatePhase(int baseFreq) {
    // apply detune
    final detuneFreq = baseFreq + _detuneVal;

    final inc = (detuneFreq * mul).shr1;
    _phase = (_phase + inc) & 0xfffff;
  }

  // modulation: -0xfff..0xfff
  int generateOutput(int modulation) {
    // phase: 24bit 0..0xfffff
    final phase = (modulation + _phase.shr10).mask10;
    final qPhase = (phase.bit8 ? ~phase : phase).mask8;

    // level: 0(loud)-0x1fff(quiet) 13bit
    int level = _logSinTable[qPhase] + _egLevel.shl2 + (am ? ch._lfoAmVal : 0);
    if (level < 0) {
      level = 0;
    } else if (level > 0x1fff) {
      level = 0x1fff;
    }

    // output: 0(quiet)-0x1fff(loud) 13bit
    final output = (_expTable[(~level).mask8] | 0x400).shl2 >> level.shr8;

    // out: 14bit = 13bit + sign
    final out = phase.bit9 ? -output : output;

    return out;
  }

  String debug() {
    return '$no eg:$ar $dr $sr $sl $rr s:$_egState $_egAttenuation $_egLevel';
  }
}

class Channel {
  final int no;
  late final List<Op> op;
  late final Op _op1, _op2, _op3, _op4;

  Channel(this.no) {
    op =
        List.unmodifiable([Op(this, 1), Op(this, 2), Op(this, 3), Op(this, 4)]);
    _op1 = op[0];
    _op2 = op[1];
    _op3 = op[2];
    _op4 = op[3];
  }

  int freq = 0;
  int block = 0;

  setFreq() {
    // in ch3 special mode, only op4 follows the channel frequency
    for (final o in isCh3Special ? [op[3]] : op) {
      o.freq = freq;
      o.block = block;
      o.keyCode = block.shl2 | _keyCodeTable[freq.shr7];
    }
  }

  int algo = 0;
  int feedback = 0;

  int lfoAms = 0;
  int lfoFms = 0;
  bool lfoEnabled = false;

  set lfoFreq(int freq) {
    _lfoCounterMask = _lfoCycles[freq];
  }

  static const _lfoCycles = [108, 77, 71, 67, 62, 44, 8, 5];

  int _lfoCounterMask = 0;
  int _lfoCounter = 0;
  int _lfoPhase = 0; // 0-0x7f
  int _lfoFmPhase = 0; // 0-0x1f
  int _lfoAmVal = 0; // 0-0x7f

  bool outLeft = false;
  bool outRight = false;

  bool isCh3Special = false;

  int counter = 0;

  int egClockCounter = 0; // clock counter for EG
  int globalClockCounter = 0; // global counter of FM module

  // output of the last render: [0, samples) is valid
  var buffer = Float32List(1000);
  var opBuffer = List<Int32List>.generate(4, (j) => Int32List(1000));

  int calcLfoFreq(int freq, int block) {
    if (!lfoEnabled) {
      return (freq << (block + 1)).shr2;
    }

    final freqH = freq.shr4;
    final lfoPhase = (_lfoFmPhase ^ (_lfoFmPhase.bit3 ? 0x0f : 0)).mask3;
    final lfoVal = (freqH >> _lfoFms1Table[lfoFms][lfoPhase]) +
        (freqH >> _lfoFms2Table[lfoFms][lfoPhase]);
    final lfoVal2 = lfoVal << (lfoFms > 5 ? lfoFms - 5 : 0);
    final lfoFreq = freq.shl1 + (_lfoFmPhase.bit4 ? -lfoVal2 : lfoVal);

    final baseFreq = (lfoFreq << block).shr2;
    return baseFreq;
  }

  @pragma('vm:prefer-inline')
  int withFeedback(Op op) {
    final input = op.generateOutput(0);
    return feedback == 0
        ? input
        : op.generateOutput(feedback == 0 ? 0 : (input >> (10 - feedback)));
  }

  static const _lfoAmsShift = [7, 3, 1, 0];

  // 1 sample = 1/44100 sec. renders [samples] samples into [buffer]
  void render(int samples) {
    if (buffer.length < samples) {
      buffer = Float32List(samples);
      opBuffer = List<Int32List>.generate(4, (j) => Int32List(samples));
    }
    final buf = buffer;
    final ob0 = opBuffer[0];
    final ob1 = opBuffer[1];
    final ob2 = opBuffer[2];
    final ob3 = opBuffer[3];
    final op1o = _op1, op2o = _op2, op3o = _op3, op4o = _op4;

    for (int i = 0; i < samples; i++) {
      if (lfoEnabled) {
        if (_lfoCounter & _lfoCounterMask == _lfoCounterMask) {
          _lfoCounter = 0;
          _lfoPhase++;
        } else {
          _lfoCounter++;
        }

        _lfoPhase &= (lfoEnabled ? 0x7f : 0x00);

        _lfoFmPhase = _lfoPhase.shr2;
        final lfoAmPhase =
            (_lfoPhase.bit6 ? _lfoPhase ^ 0x3f : _lfoPhase.mask6).shl1;
        _lfoAmVal = lfoAmPhase >> _lfoAmsShift[lfoAms];
      }

      final baseFreq = calcLfoFreq(freq, block);

      if (isCh3Special) {
        op1o.updatePhase(calcLfoFreq(op1o.freq, op1o.block));
        op2o.updatePhase(calcLfoFreq(op2o.freq, op2o.block));
        op3o.updatePhase(calcLfoFreq(op3o.freq, op3o.block));
        op4o.updatePhase(baseFreq);
      } else {
        op1o.updatePhase(baseFreq);
        op2o.updatePhase(baseFreq);
        op3o.updatePhase(baseFreq);
        op4o.updatePhase(baseFreq);
      }

      globalClockCounter += 144;
      if (egClockCounter < globalClockCounter ~/ 351) {
        egClockCounter++;
        op1o.updateEnvelope();
        op2o.updateEnvelope();
        op3o.updateEnvelope();
        op4o.updateEnvelope();
      }

      // an operator at the max attenuation outputs 0 for any phase and
      // modulation (the level is shifted out): skip a silent channel
      if (op1o._egLevel == Op.egAttenuationMask &&
          op2o._egLevel == Op.egAttenuationMask &&
          op3o._egLevel == Op.egAttenuationMask &&
          op4o._egLevel == Op.egAttenuationMask) {
        ob0[i] = 0;
        ob1[i] = 0;
        ob2[i] = 0;
        ob3[i] = 0;
        buf[i] = 0.0;
        continue;
      }

      double out = 0;
      int op1 = withFeedback(op1o);
      int op2 = 0;
      int op3 = 0;
      int op4 = 0;

      switch (algo) {
        case 0:
          // 0: 1->2->3->4->out
          op2 = op2o.generateOutput(op1.shr1);
          op3 = op3o.generateOutput(op2.shr1);
          op4 = op4o.generateOutput(op3.shr1);
          out = op4 / Op.outMask;
          break;
        case 1:
          // 1: 1->3 2->3->4->out
          op2 = op2o.generateOutput(0);
          op3 = op3o.generateOutput((op1 + op2).shr2);
          op4 = op4o.generateOutput(op3.shr1);
          out = op4 / Op.outMask;
          break;
        case 2:
          // 2: 1->4 2->3->4->out
          op2 = op2o.generateOutput(0);
          op3 = op3o.generateOutput(op2.shr1);
          op4 = op4o.generateOutput((op1 + op3).shr2);
          out = op4 / Op.outMask;
          break;
        case 3:
          // 3: 1->2->4->out 3->4->out
          op2 = op2o.generateOutput(op1.shr1);
          op3 = op3o.generateOutput(0);
          op4 = op4o.generateOutput((op2 + op3).shr2);
          out = op4 / Op.outMask;
          break;
        case 4:
          // 4: 1->2->out 3->4->out
          op2 = op2o.generateOutput(op1.shr1);
          op3 = op3o.generateOutput(0);
          op4 = op4o.generateOutput(op3.shr1);
          out = (op2 + op4) / 2 / Op.outMask;
          break;
        case 5:
          // 5: 1->2->out 1->3->out 1->4->out
          op2 = op2o.generateOutput(op1.shr1);
          op3 = op3o.generateOutput(op1.shr1);
          op4 = op4o.generateOutput(op1.shr1);
          out = (op2 + op3 + op4) / 3 / Op.outMask;
          break;
        case 6:
          // 6: 1->2->out 3->out 4->out
          op2 = op2o.generateOutput(op1.shr1);
          op3 = op3o.generateOutput(0);
          op4 = op4o.generateOutput(0);
          out = (op2 + op3 + op4) / 3 / Op.outMask;
          break;
        case 7:
          // 7: 1->out 2->out 3->out 4->out
          op2 = op2o.generateOutput(0);
          op3 = op3o.generateOutput(0);
          op4 = op4o.generateOutput(0);
          out = (op1 + op2 + op3 + op4) / 4 / Op.outMask;
          break;
      }

      ob0[i] = op1;
      ob1[i] = op2;
      ob2[i] = op3;
      ob3[i] = op4;

      buf[i] = out;
    }
  }

  bool enableDebug = true;

  String debug({bool verbose = false}) {
    if (!enableDebug) {
      return "";
    }

    final lr = outLeft && outRight
        ? "C"
        : outLeft
            ? "L"
            : outRight
                ? "R"
                : "-";
    final lfo =
        "${lfoEnabled ? lfoAms.toString().padLeft(1) : "-"}${lfoEnabled ? lfoFms.toString().padLeft(1) : "-"}";
    final status =
        "${no.toString().padLeft(1)}:$lr${(block.shl2 | freq.shr8).x2} $algo$feedback $lfo";

    final ops = op.map((o) => o.ssgEg.bit3 ? "s" : "a").join();
    final verboseOps = op.map((o) => o.debug()).join(' ');

    return "$status ${verbose ? verboseOps : ops}";
  }
}

class Ym2612 {
  final _channels = List.generate(6, (i) => Channel(i + 1));

  final _regs = [0, 0];

  static const _bitTimerA = 0x01;
  static const _bitTimerB = 0x02;

  Ym2612();

  int _lfoFreq = 0;

  static const _ch3ModeNone = 0;
  // static const _ch3ModeMultiFreq = 1;
  static const _ch3ModeCsm = 2;
  int _ch3Mode = _ch3ModeNone;

  bool _enableTimerA = false;
  bool _enableTimerB = false;

  bool _notifyTimerAOverflow = false;
  bool _notifyTimerBOverflow = false;

  int _timerA = 0; // 18 * (1024 - TIMER A) microseconds, all 0 is the longest
  int _timerB = 0; // 288 * (256 - TIMER B ) microseconds, all 0 is the longest

  int _timerOverflow = 0;

  int _timerCountA = 0;
  int _timerCountB = 0;

  int _dacData = 0;
  bool _dacEnabled = false;

  // TIMERA_period = 9us x (1024 -TIMER)
  // TIMERB_period = 9us x 16 x (256 -TIMER)
  // 18.773us ~= 1_000_000ms / (m68clock / 144); where m68clock / 144 = 1 sample
  countTimer(int samples) {
    if (_enableTimerA) {
      _timerCountA -= samples * 2;

      if (_timerCountA <= 0) {
        while (_timerCountA <= 0) {
          _timerCountA += 1024 - _timerA;
        }

        if (_notifyTimerAOverflow) {
          _timerOverflow |= _bitTimerA;
        }

        if (_ch3Mode == _ch3ModeCsm) {
          for (final op in _channels[2].op) {
            op.keyOn(retrigger: true);
          }
        }
      }
    }

    if (_enableTimerB) {
      _timerCountB -= samples * 2;

      if (_timerCountB <= 0) {
        while (_timerCountB <= 0) {
          _timerCountB += (256 - _timerB).shl4;
        }

        if (_notifyTimerBOverflow) {
          //print("timerB overflow");
          _timerOverflow |= _bitTimerB;
        }
      }
    }
  }

  int read8(int part) {
    return _timerOverflow;
  }

  writePort8(int part, int value) {
    _regs[part] = value;
  }

  writeData8(int part, int value) {
    final reg = _regs[part];
    final chBase = part + part + part;
    final chNo = chBase + reg.mask2;
    if (chNo > 5) {
      // print("Invalid channel $chNo");
      return;
    }

    switch (reg) {
      case 0x22: // LFO
        _lfoFreq = value.mask3;
        for (final ch in _channels) {
          ch.lfoFreq = _lfoFreq;
          ch.lfoEnabled = value.bit3;
        }
        break;

      case 0x24: // Timer A Low
        _timerA = _timerA.mask2 | value.shl2;
        break;

      case 0x25: // Timer A High
        _timerA = _timerA & 0x3fc | value.mask2;
        break;

      case 0x26: // Timer B
        _timerB = value;
        break;

      case 0x27: // Timer Control
        _ch3Mode = value.shr6.mask2;
        _channels[2].isCh3Special = _ch3Mode != _ch3ModeNone;

        // reset flags take effect immediately on write
        if (value.bit5) {
          _timerOverflow &= ~_bitTimerB;
        }
        if (value.bit4) {
          _timerOverflow &= ~_bitTimerA;
        }

        _notifyTimerBOverflow = value.bit3;
        _notifyTimerAOverflow = value.bit2;

        // counters are reloaded only when the load bit goes 0 -> 1
        if (value.bit1 && !_enableTimerB) {
          _timerCountB = (256 - _timerB).shl4;
        }
        _enableTimerB = value.bit1;

        if (value.bit0 && !_enableTimerA) {
          _timerCountA = 1024 - _timerA;
        }
        _enableTimerA = value.bit0;
        break;

      case 0x28: // Operator Control
        if (value.mask2 == 0x03) {
          return; // invalid channel
        }
        final ch = _channels[value.mask2 + (value.bit2 ? 3 : 0)];

        for (var op = 0; op < 4; op++) {
          (value >> (op + 4)).mask1 == 1
              ? ch.op[op].keyOn()
              : ch.op[op].keyOff();
        }
        break;

      case 0x2a: // dac data
        _dacData = value.mask8;
        break;

      case 0x2b: // dac control
        _dacEnabled = value.bit7;
        return;
    }

    if (0x30 <= reg && reg < 0xb8 && reg.mask2 == 0x03) {
      return; // invalid channel
    }

    if (0x30 <= reg && reg < 0xa0) {
      final op = _channels[chNo].op[[0, 2, 1, 3][reg.shr2.mask2]];

      switch (reg & 0xf0) {
        case 0x30: // DT, MUL
          op.dt = value.shr4.mask3;
          op.mul = value.shl1 & 0x1e;
          if (op.mul == 0) {
            op.mul = 1;
          }
          break;
        case 0x40: // TL
          op.tl = value.mask7;
          break;
        case 0x50: // RS(KS), AR
          op.ar = value.mask5;
          op.rs = value.shr6.mask2;
          break;
        case 0x60: // AM, DR(D1R)
          op.am = value.bit7;
          op.dr = value.mask5;
          break;
        case 0x70: // SR(D2R)
          op.sr = value.mask5;
          break;
        case 0x80: // SL(D1L), RR
          op.sl = value.shr4.mask4;
          op.rr = value.mask4;
          break;
        case 0x90: // SSG-EG
          op.ssgEg = value.mask4;
          break;
      }
      return;
    }

    if (0xa0 <= reg && reg < 0xb8) {
      if (0xa8 <= reg && reg < 0xb0) {
        // ch3 special mode fnum/block: a9/ad -> op1, aa/ae -> op2, a8/ac -> op3
        if (part == 0) {
          final op = _channels[2].op[[2, 0, 1][reg.mask2]];
          if (reg < 0xac) {
            op.freq = op.freq.setL8(value);
            op.keyCode = op.block.shl2 | _keyCodeTable[op.freq.shr7];
          } else {
            op.freq = op.freq.setH8(value.mask3);
            op.block = value.shr3.mask3;
          }
        }
        return;
      }

      final ch = _channels[chNo];

      final func = reg & 0xfc;
      switch (func) {
        case 0xa0: // FNUM
          ch.freq = ch.freq.setL8(value);
          ch.setFreq();
          break;
        case 0xa4: // FNUM
          ch.freq = ch.freq.setH8(value.mask3);
          ch.block = value.shr3.mask3;
          break;
        case 0xb0: // FB & ALGO
          ch.feedback = value.shr3.mask3;
          ch.algo = value.mask3;
          break;
        case 0xb4: // L, R and LFO
          ch.outLeft = value.bit7;
          ch.outRight = value.bit6;
          ch.lfoAms = value.shr4.mask2;
          ch.lfoFms = value.mask3;
          break;
      }
      return;
    }
  }

  void reset() {
    for (final ch in _channels) {
      for (final op in ch.op) {
        op.freq = 0;
        op.block = 0;
        op.keyCode = 0;
        op.dt = 0;
        op.mul = 0;
        op.tl = 0;
        op.ar = 0;
        op.rs = 0;
        op.am = false;
        op.dr = 0;
        op.sr = 0;
        op.sl = 0;
        op.rr = 0;
        op.ssgEg = 0;
        op.keyOff();
      }

      ch.freq = 0;
      ch.block = 0;
      ch.algo = 0;
      ch.feedback = 0;
      ch.lfoAms = 0;
      ch.lfoFms = 0;
      ch.lfoEnabled = false;
      ch.outLeft = false;
      ch.outRight = false;
      ch.counter = 0;
      ch.egClockCounter = 0;
      ch.globalClockCounter = 0;
    }

    _lfoFreq = 0;
    _ch3Mode = _ch3ModeNone;
    _timerA = 0;
    _timerB = 0;
    _enableTimerA = false;
    _enableTimerB = false;
    _notifyTimerAOverflow = false;
    _notifyTimerBOverflow = false;
    _timerOverflow = 0;
    _timerCountA = 0;
    _timerCountB = 0;
    _dacData = 0;
    _dacEnabled = false;

    elapsedSamples = 0;
  }

  // input:7.670453 MHz / 6 prescale / 4 op / 6 channels = output:53.267 kHz @ ntsc
  void setClockHz(int hz) {
    sampleHz = hz ~/ 6 ~/ 4 ~/ 6;
  }

  int sampleHz = 53267;

  int elapsedSamples = 0;

  // called 15.720 kHz - DAC should be called more frequently
  Float32List render(int samples) {
    countTimer(samples);

    final buffer = Float32List(samples * 2);
    final length = buffer.length;

    for (int c = 0; c < _channels.length; c++) {
      final ch = _channels[c];
      final left = ch.outLeft;
      final right = ch.outRight;
      if (_dacEnabled && ch.no == 6) {
        // mix dac
        final dacValue = (_dacData - 127) / 128 / 6;
        for (int i = 0; i < length; i += 2) {
          buffer[i + 0] += left ? dacValue : 0;
          buffer[i + 1] += right ? dacValue : 0;
        }
        continue;
      }

      // mix fm
      ch.render(samples);
      final out = ch.buffer;
      for (int i = 0; i < length; i += 2) {
        final dacValue = out[i.shr1] / 4;
        buffer[i + 0] += left ? dacValue : 0;
        buffer[i + 1] += right ? dacValue : 0;
      }
    }

    elapsedSamples += samples;

    return buffer;
  }

  List<int> opBuffer(int ch, int op) {
    return _channels[ch].opBuffer[op];
  }

  String dump() {
    final ch = _channels.map((c) => c.debug()).join(' ');
    return "fm:${_ch3Mode.toString().padLeft(1)}${_dacEnabled ? "D" : "-"} ${_timerCountA.x4} ${_timerCountB.x2} $ch";
  }
}
