import 'dart:typed_data';

import 'package:fnesemu/core/md/md.dart';
import 'package:fnesemu/util/int.dart';

class Op {
  bool enabled = false;

  int dt1 = 0;
  int mul = 0;

  int tl = 0;
  int ar = 0;
  int rs = 0;

  bool am = false;
  int d1r = 0;

  int d2r = 0;

  int d1l = 0;
  int rr = 0;

  int ssgEg = 0;
}

class Channel {
  final int no;
  Channel(this.no);

  final op = List<Op>.filled(4, Op());

  int freq = 0;
  int algo = 0;
  int feedback = 0;

  int lfoAms = 0;
  int lfoFms = 0;
  bool lfoEnabled = false;

  bool outLeft = false;
  bool outRight = false;

  int counter = 0;

  keyOn() {}

  var buffer = Float32List(1000);

  var out = 1.0; // pulse wave (temporary)

  // 1 sample = 1/44100 sec
  Float32List render(int samples) {
    if (buffer.length != samples) {
      buffer = Float32List(samples);
    }

    for (int i = 0; i < samples; i++) {
      counter = (counter - 1) & 0xfff;

      if (counter == 1) {
        counter = _clip(freq, 0, 0xfff);
        out = 1.0 - out;
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

  int timerA = 0; // 18 * (1024 - TIMER A) microseconds, all 0 is the longest
  int timerB = 0; // 288 * (256 - TIMER B ) microseconds, all 0 is the longest

  bool enableTimerA = false;
  bool enableTimerB = false;

  bool timerAOverflow = false;
  bool timerBOverflow = false;

  int _timerCountA = 0;
  int _timerCountB = 0;

  int dacData = 0;
  bool dacEnabled = false;

  resetTimerA() => _timerCountA = timerA;
  resetTimerB() => _timerCountB = timerB;

  countTimer() => {};
}

class Ym2612 {
  Ym2612();

  var _buffer = Float32List(1000);

  Float32List get audioBuffer => _buffer;

  final _synth = List.generate(2, (i) => Synth(i));
  final _regs = [0, 0];

  int readPort8(int part) {
    return 0;
  }

  int readData(int part) {
    return 0;
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
        synth.timerA = synth.timerA & 0x03 | value << 2;
        break;

      case 0x25: // Timer A High
        synth.timerA = synth.timerA & 0x3fc | value & 0x03;
        break;

      case 0x26: // Timer B
        synth.timerB = value;
        break;

      case 0x27: // Timer Control
        synth.isCh3Special = value.bit7;
        if (value.bit5) {
          synth.resetTimerB();
        }
        if (value.bit4) {
          synth.resetTimerA();
        }
        synth.timerBOverflow = value.bit3;
        synth.timerAOverflow = value.bit2;
        synth.enableTimerB = value.bit1;
        synth.enableTimerA = value.bit0;
        break;

      case 0x28: // Operator Control
        //synth.ch[0].op[0].enabled = value.bit0;
        break;
      case 0x2a: // dac data
        synth.dacData = value & 0x7f;
        break;

      case 0x2b: // dac control
        synth.dacEnabled = value.bit7;
        return;
    }

    if (0x30 <= reg && reg < 0xa0) {
      final ch = reg & 0x03;
      final op = synth.ch[ch].op[value >> 2 & 0x03];

      final func = reg & 0xf0;

      switch (func) {
        case 0x30: // DT1, MUL
          op.dt1 = value >> 4 & 0x07;
          op.mul = value & 0x0f;
          break;
        case 0x40: // TL
          op.tl = value & 0x7f;
          break;
        case 0x50: // KS, AR
          op.ar = value & 0x0f;
          op.rs = value >> 6 & 0x03;
          break;
        case 0x60: // AM, D1R
          op.am = value.bit7;
          op.d1r = value & 0x1f;
          break;
        case 0x70: // D2R
          op.d2r = value & 0x1f;
          break;
        case 0x80: // D1L, RR
          op.d1l = value >> 4 & 0x0f;
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
            synth.ch3freq[reg - 0xa7] = synth.ch3freq[reg - 0xa7].setL8(value);
            return;
          case 0xac: // FNUM
          case 0xad:
          case 0xae:
            synth.ch3freq[reg - 0xa7] =
                synth.ch3freq[reg - 0xa7].setH8(value & 0x3f);
            return;
        }
      }

      final func = reg & 0xfc;
      switch (func) {
        case 0xa0: // FNUM
          ch.freq = ch.freq.setL8(value);
          ch.keyOn();
          break;
        case 0xa4: // FNUM
          ch.freq = ch.freq.setH8(value & 0x3f);
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

  // input:7.670453 MHz  output:53.267 kHz - ntsc
  static const fmAudioClockHz = 53267;

  // every passed clocks ~= 1368 per 1 scanline.  called 15.720 kHz
  Float32List render(int clocks) {
    final samples = fmAudioClockHz * clocks ~/ Md.systemClockHz_;

    final buffer = Float32List(samples * 2);

    for (final synth in _synth) {
      for (final ch in synth.ch) {
        if (synth.dacEnabled && ch.no == 6) {
          // mix dac
          for (int i = 0; i < audioBuffer.length / 2; i++) {
            buffer[i * 2] += synth.dacData / 256 / 6;
            buffer[i * 2 + 1] += synth.dacData / 256 / 6;
          }

          continue;
        }

        // mix fm
        final out = ch.render(samples);

        if (ch.outLeft) {
          for (int i = 0; i < out.length; i++) {
            buffer[i * 2] += out[i] / 6;
          }
        }

        if (ch.outRight) {
          for (int i = 0; i < out.length; i++) {
            buffer[i * 2 + 1] += out[i] / 6;
          }
        }
      }
    }

    return buffer;
  }
}
