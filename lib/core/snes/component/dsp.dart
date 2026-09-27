import 'package:fnesemu/util/int.dart';

import 'spc700.dart';

enum EnvMode { attack, decay, sustain, release, off }

class Voice {
  int volL = 0, volR = 0; // signed 8-bit
  int pitch = 0; // 14-bit, 0x1000 = normal speed
  int srcn = 0;
  int adsr1 = 0, adsr2 = 0;
  int gain = 0;
  int envx = 0; // 0-0x7ff, last envelope value (for $x8 readback)
  int outx = 0; // last output sample >>8 (for $x9 readback)

  // playback state
  bool keyOn = false;
  int brrAddr = 0; // current BRR block address
  int nibbleIndex = 16; // 0-15; 16 means "need to decode next block"
  int pitchCounter = 0; // 15-bit fractional sample position
  int hist1 = 0, hist2 = 0; // BRR decode history (t-1, t-2)
  List<int> decoded = List.filled(16, 0); // current block's decoded samples
  bool blockEnd = false; // current block has BRR "end" flag set
  bool blockLoop = false; // current block has BRR "loop" flag set

  EnvMode envMode = EnvMode.off;
  int env = 0; // 0-0x7ff current envelope level
  int envTick = 0; // sub-counter toward the next envelope rate step
}

/// S-DSP: 8 BRR-sample voices with ADSR/GAIN envelopes, mixed to stereo.
///
/// implemented: BRR decode, ADSR envelope (attack/decay/sustain/release)
/// and direct GAIN, pitch with linear interpolation between samples (real
/// hardware uses a 4-tap Gaussian filter - documented simplification),
/// per-voice L/R volume, main volume, KON/KOFF, ENDX, noise generator
/// (NON), and a simplified echo (delay + feedback, no FIR filter - real
/// hardware applies an 8-tap FIR to the echo input before writing it to
/// the buffer; here the raw mix is written directly).
/// NOT implemented: pitch modulation (PMON), the FIR filter coefficients.
class Dsp {
  late final Spc700 spc; // set by Spc700's constructor

  final voices = List.generate(8, (_) => Voice());

  int mainVolL = 0, mainVolR = 0;
  int dir = 0; // source directory page (DIR << 8)
  int flg = 0xe0; // FLG: bit7=reset,bit6=mute,bit5=echo-write-disable
  int endx = 0; // per-voice "reached loop/end" flags (read, write clears)
  int nonMask = 0; // $3D: per-voice noise-instead-of-BRR enable
  int eonMask = 0; // $4D: per-voice echo-send enable
  int efb = 0; // $0D: echo feedback (signed 8-bit)
  int evolL = 0, evolR = 0; // $2C/$3D: echo volume L/R (signed 8-bit)
  int esa = 0; // $6D: echo buffer start page
  int edl = 0; // $7D: echo delay, 0-15 (each unit = 2KB = ~32ms buffer)

  int _noiseLfsr = 0x4000; // 15-bit, must stay non-zero
  int _noiseTick = 0;
  int _noiseSampleValue = 0;

  int _echoPos = 0; // byte offset within the echo buffer

  // raw scratch for PMON/FIR registers we don't implement, so reads
  // return the last-written value.
  final _scratch = List<int>.filled(0x80, 0);

  static const _rateToSamples = [
    0xffffffff, 2048, 1536, 1280, 1024, 768, 640, 512, //
    384, 320, 256, 192, 160, 128, 96, 80, //
    64, 48, 40, 32, 24, 20, 16, 12, //
    10, 8, 6, 5, 4, 3, 2, 1, //
  ];

  void reset() {
    for (final v in voices) {
      v.volL = 0;
      v.volR = 0;
      v.pitch = 0;
      v.srcn = 0;
      v.adsr1 = 0;
      v.adsr2 = 0;
      v.gain = 0;
      v.envx = 0;
      v.outx = 0;
      v.keyOn = false;
      v.brrAddr = 0;
      v.nibbleIndex = 16;
      v.pitchCounter = 0;
      v.hist1 = 0;
      v.hist2 = 0;
      v.envMode = EnvMode.off;
      v.env = 0;
    }
    mainVolL = 0;
    mainVolR = 0;
    dir = 0;
    flg = 0xe0;
    endx = 0;
    nonMask = 0;
    eonMask = 0;
    efb = 0;
    evolL = 0;
    evolR = 0;
    esa = 0;
    edl = 0;
    _noiseLfsr = 0x4000;
    _noiseTick = 0;
    _noiseSampleValue = 0;
    _echoPos = 0;
    _scratch.fillRange(0, _scratch.length, 0);
  }

  // -------------------------------------------------------------- ports
  int read(int addr) {
    addr &= 0x7f;
    final voiceIdx = addr.shr4;
    final reg = addr & 0x0f;
    if (voiceIdx < 8) {
      final v = voices[voiceIdx];
      switch (reg) {
        case 0x0:
          return v.volL & 0xff;
        case 0x1:
          return v.volR & 0xff;
        case 0x2:
          return v.pitch & 0xff;
        case 0x3:
          return v.pitch.shr8 & 0xff;
        case 0x4:
          return v.srcn;
        case 0x5:
          return v.adsr1;
        case 0x6:
          return v.adsr2;
        case 0x7:
          return v.gain;
        case 0x8:
          return v.envx.shr4 & 0x7f;
        case 0x9:
          return v.outx.shr8 & 0xff;
      }
    }
    switch (addr) {
      case 0x0c:
        return mainVolL & 0xff;
      case 0x1c:
        return mainVolR & 0xff;
      case 0x2c:
        return evolL & 0xff;
      case 0x3c:
        return evolR & 0xff;
      case 0x0d:
        return efb & 0xff;
      case 0x3d:
        return nonMask;
      case 0x4d:
        return eonMask;
      case 0x5d:
        return dir.shr8 & 0xff;
      case 0x6d:
        return esa;
      case 0x7d:
        return edl;
      case 0x6c:
        return flg;
      case 0x7c:
        return endx;
      default:
        return _scratch[addr];
    }
  }

  void write(int addr, int val) {
    addr &= 0x7f;
    val &= 0xff;
    _scratch[addr] = val;
    final voiceIdx = addr.shr4;
    final reg = addr & 0x0f;
    if (voiceIdx < 8) {
      final v = voices[voiceIdx];
      switch (reg) {
        case 0x0:
          v.volL = val;
          return;
        case 0x1:
          v.volR = val;
          return;
        case 0x2:
          v.pitch = v.pitch.setL8(val);
          return;
        case 0x3:
          v.pitch = (v.pitch & 0x00ff) | ((val & 0x3f).shl8);
          return;
        case 0x4:
          v.srcn = val;
          return;
        case 0x5:
          v.adsr1 = val;
          return;
        case 0x6:
          v.adsr2 = val;
          return;
        case 0x7:
          v.gain = val;
          return;
        case 0x8:
        case 0x9:
          return; // ENVX/OUTX are read-only
      }
    }
    switch (addr) {
      case 0x0c:
        mainVolL = val;
        break;
      case 0x1c:
        mainVolR = val;
        break;
      case 0x2c:
        evolL = val;
        break;
      case 0x3c:
        evolR = val;
        break;
      case 0x0d:
        efb = val;
        break;
      case 0x3d:
        nonMask = val;
        break;
      case 0x4d:
        eonMask = val;
        break;
      case 0x4c: // KON
        for (int i = 0; i < 8; i++) {
          if (val.bit(i)) {
            _keyOn(voices[i]);
            endx &= ~(1 << i);
          }
        }
        break;
      case 0x5c: // KOFF
        for (int i = 0; i < 8; i++) {
          if (val.bit(i)) voices[i].envMode = EnvMode.release;
        }
        break;
      case 0x5d:
        dir = (val).shl8;
        break;
      case 0x6d:
        esa = val;
        break;
      case 0x7d:
        edl = val & 0x0f;
        _echoPos = 0;
        break;
      case 0x6c:
        flg = val;
        if (val.bit7) {
          // soft reset: silence all voices and clear ENDX. does NOT wipe
          // the register file (volumes, DIR, etc. survive on real hardware)
          for (final v in voices) {
            v.envMode = EnvMode.off;
            v.env = 0;
            v.keyOn = false;
          }
          endx = 0;
        }
        break;
      case 0x7c:
        endx = 0; // any write clears ENDX
        break;
      default:
        break; // echo/noise/PMON/FIR: stored above, not applied
    }
  }

  void _keyOn(Voice v) {
    v.keyOn = true;
    v.nibbleIndex = 16; // force a fresh block decode
    v.pitchCounter = 0;
    v.hist1 = 0;
    v.hist2 = 0;
    v.env = 0;
    v.envMode = EnvMode.attack;
    // source directory entry: 4 bytes per source at dir + srcn*4:
    // [startL,startH, loopL,loopH]
    v.brrAddr = _dirEntry(v, 0);
  }

  /// reads the source directory entry for [v]: 4 bytes per source at
  /// dir + srcn*4 = [startL,startH, loopL,loopH]. [offset] 0=start, 2=loop.
  int _dirEntry(Voice v, int offset) {
    final entry = (dir + v.srcn * 4 + offset) & 0xffff;
    return _ram(entry) | _ram(entry + 1).shl8;
  }

  int _ram(int addr) => spc.ram[addr & 0xffff];

  // ------------------------------------------------------------- envelope
  void _stepEnvelope(Voice v) {
    if (v.envMode == EnvMode.off) return;

    if (v.envMode == EnvMode.release) {
      // release (KOFF) ignores ADSR/GAIN and decreases by 8 every sample
      v.env -= 8;
      if (v.env <= 0) {
        v.env = 0;
        v.envMode = EnvMode.off;
      }
      return;
    }

    if (!v.adsr1.bit7) {
      // direct GAIN mode - only the simple "fixed value" form (bit7=0 of
      // GAIN) is implemented; the increase/decrease/bent-line curve modes
      // (bit7=1) are treated the same as fixed, a documented approximation.
      v.env = (v.gain & 0x7f) << 4;
      return;
    }

    int rate;
    switch (v.envMode) {
      case EnvMode.attack:
        rate = (v.adsr1 & 0x0f) * 2 + 1;
        break;
      case EnvMode.decay:
        rate = ((v.adsr1.shr4) & 0x07) * 2 + 16;
        break;
      case EnvMode.sustain:
        rate = v.adsr2 & 0x1f;
        break;
      case EnvMode.release:
      case EnvMode.off:
        return;
    }

    final period = _rateToSamples[rate];
    if (period == 0xffffffff) return; // rate 0: never advances
    v.envTick = (v.envTick + 1);
    if (v.envTick < period) return;
    v.envTick = 0;

    switch (v.envMode) {
      case EnvMode.attack:
        v.env += 32;
        if (v.env >= 0x7ff) {
          v.env = 0x7ff;
          v.envMode = EnvMode.decay;
        }
        break;
      case EnvMode.decay:
        {
          final sustainLevel = (((v.adsr2.shr5) & 0x07) + 1) * 0x100;
          v.env -= ((v.env - 1) >> 8) + 1;
          if (v.env < 0) v.env = 0;
          if (v.env <= sustainLevel) v.envMode = EnvMode.sustain;
        }
        break;
      case EnvMode.sustain:
        v.env -= ((v.env - 1) >> 8) + 1;
        if (v.env < 0) v.env = 0;
        break;
      case EnvMode.release:
      case EnvMode.off:
        break;
    }
  }

  // ---------------------------------------------------------------- BRR
  int _clamp16(int v) {
    if (v > 32767) return 32767;
    if (v < -32768) return -32768;
    return v;
  }

  void _decodeNextBlock(Voice v) {
    final header = _ram(v.brrAddr);
    final shift = header.shr4 & 0x0f;
    final filter = header.shr2 & 0x03;
    final loop = header.bit1;
    final end = header.bit0;

    final samples = List<int>.filled(16, 0);
    for (int i = 0; i < 8; i++) {
      final byte = _ram(v.brrAddr + 1 + i);
      final nibbles = [byte.shr4 & 0x0f, byte & 0x0f];
      for (int j = 0; j < 2; j++) {
        var n = nibbles[j];
        if (n >= 8) n -= 16; // sign-extend 4-bit
        int raw = shift <= 12 ? (n << shift) >> 1 : (n < 0 ? -2048 : 0);

        int pred;
        switch (filter) {
          case 0:
            pred = 0;
            break;
          case 1:
            pred = v.hist1 + ((-v.hist1) >> 4);
            break;
          case 2:
            pred = v.hist1 * 2 +
                ((-(v.hist1 * 3)) >> 5) -
                v.hist2 +
                (v.hist2 >> 4);
            break;
          default:
            pred = v.hist1 * 2 +
                ((-(v.hist1 * 13)) >> 6) -
                v.hist2 +
                ((v.hist2 * 3) >> 4);
        }

        final s = _clamp16(raw + pred);
        v.hist2 = v.hist1;
        v.hist1 = s;
        samples[i * 2 + j] = s;
      }
    }
    v.decoded = samples;
    v.nibbleIndex = 0;

    v.blockEnd = end;
    v.blockLoop = end && loop;
    // an end block continues from the source's loop address (read from the
    // directory at this point, like hardware does)
    v.brrAddr = end ? _dirEntry(v, 2) : (v.brrAddr + 9) & 0xffff;
  }

  /// a non-looping end block keys the voice off with its envelope at zero.
  void _silence(Voice v) {
    v.envMode = EnvMode.off;
    v.env = 0;
    v.keyOn = false;
  }

  /// advances the noise LFSR by one step (15-bit, feedback = bit0 XOR bit1
  /// fed back into bit14 - the commonly documented SNES noise polynomial).
  void _updateNoise() {
    final feedback = (_noiseLfsr & 1) ^ ((_noiseLfsr.shr1) & 1);
    _noiseLfsr = (_noiseLfsr.shr1) | (feedback << 14);
    _noiseSampleValue = _noiseLfsr.bit14 ? (_noiseLfsr - 0x8000) : _noiseLfsr;
  }

  /// advances all voices by one output sample (called at the DSP's native
  /// 32000Hz rate) and returns (left, right) as floats in roughly [-1, 1].
  (double, double) mixSample() {
    // noise LFSR ticks at a rate selected by FLG bits0-4 (same period table
    // used by the envelope rates).
    final noisePeriod = _rateToSamples[flg & 0x1f];
    if (noisePeriod != 0xffffffff) {
      _noiseTick++;
      if (_noiseTick >= noisePeriod) {
        _noiseTick = 0;
        _updateNoise();
      }
    }

    double left = 0, right = 0;
    double echoInL = 0, echoInR = 0;

    for (int i = 0; i < 8; i++) {
      final v = voices[i];
      if (v.envMode == EnvMode.off) continue;

      if (v.nibbleIndex >= 16) {
        _decodeNextBlock(v);
        if (v.blockEnd) {
          endx |= 1 << i;
          if (!v.blockLoop) _silence(v);
        }
      }

      int sample;
      if (nonMask.bit(i)) {
        sample = _noiseSampleValue;
      } else {
        // linear interpolation toward the next decoded sample (real
        // hardware uses a 4-tap Gaussian filter - documented
        // simplification). at a block boundary we skip interpolation
        // rather than look ahead into the next (not yet decoded) block.
        final s0 = v.decoded[v.nibbleIndex];
        final next = v.nibbleIndex + 1;
        final s1 = next < 16 ? v.decoded[next] : s0;
        final frac = v.pitchCounter / 0x1000;
        sample = (s0 + (s1 - s0) * frac).round();
      }
      _stepEnvelope(v);

      final amp = sample * v.env ~/ 0x800;
      v.outx = amp;
      v.envx = v.env;

      final ampL = amp * (v.volL.rel8) / 128.0;
      final ampR = amp * (v.volR.rel8) / 128.0;
      left += ampL / 32768.0;
      right += ampR / 32768.0;
      if (eonMask.bit(i)) {
        echoInL += ampL;
        echoInR += ampR;
      }

      // advance pitch counter; step to the next nibble once we've
      // consumed a full sample period
      v.pitchCounter += v.pitch == 0 ? 0x1000 : v.pitch;
      while (v.pitchCounter >= 0x1000) {
        v.pitchCounter -= 0x1000;
        v.nibbleIndex++;
        if (v.nibbleIndex >= 16) {
          if (v.envMode == EnvMode.off) break;
          _decodeNextBlock(v);
          if (v.blockEnd) {
            endx |= 1 << i;
            if (!v.blockLoop) {
              _silence(v);
              break;
            }
          }
        }
      }
    }

    // echo: simplified delay+feedback line in APU RAM (no FIR filter - see
    // class doc). buffer holds 4 bytes/sample (L16,R16) starting at ESA.
    {
      final bufBytes = edl == 0 ? 4 : edl * 0x800;
      final addr = (esa.shl8 + _echoPos) & 0xffff;
      final echoOutL = (_ram(addr) | _ram(addr + 1).shl8).rel16;
      final echoOutR = (_ram(addr + 2) | _ram(addr + 3).shl8).rel16;

      left += echoOutL / 32768.0 * (evolL.rel8) / 128.0;
      right += echoOutR / 32768.0 * (evolR.rel8) / 128.0;

      if (!flg.bit5) {
        final newL =
            _clamp16(echoInL.round() + (echoOutL * (efb.rel8)) ~/ 128);
        final newR =
            _clamp16(echoInR.round() + (echoOutR * (efb.rel8)) ~/ 128);
        spc.ram[addr] = newL & 0xff;
        spc.ram[(addr + 1) & 0xffff] = newL.shr8 & 0xff;
        spc.ram[(addr + 2) & 0xffff] = newR & 0xff;
        spc.ram[(addr + 3) & 0xffff] = newR.shr8 & 0xff;
      }
      _echoPos = (_echoPos + 4) % bufBytes;
    }

    if (flg.bit6) return (0.0, 0.0); // FLG mute

    left *= (mainVolL.rel8) / 128.0;
    right *= (mainVolR.rel8) / 128.0;
    return (left.clamp(-1.0, 1.0), right.clamp(-1.0, 1.0));
  }
}
