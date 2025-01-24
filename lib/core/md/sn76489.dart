import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';

final _volumeTable = [
  32767, 26028, 20675, 16422, 13045, 10362, 8231, 6568, //
  5193, 4125, 3277, 2603, 2067, 1642, 1304, 0 //
].map((e) => e / 32767).toList();

class Tone {
  int freq = 0;
  int vol = 0;

  int _counter = 0;
  bool _high = false;

  Float32List render(int samples) {
    if (freq == 0 || freq == 1) {
      return Float32List(samples)..fillRange(0, samples, vol / 15);
    }

    final buf = Float32List(samples);

    for (int i = 0; i < samples; i++) {
      _counter--;

      if (_counter <= 0) {
        _high = !_high;
        _counter = freq;
      }

      buf[i] = _high ? _volumeTable[vol] : -_volumeTable[vol];
    }

    return buf;
  }
}

class Noise {
  int vol = 0;
  int tone2freq = 0;
  bool periodic = false;

  set shift(int s) {
    _freq = [0x10, 0x20, 0x40, tone2freq][s];
    _lfsr = 0x8000;
  }

  int _counter = 0;
  bool _high = false;
  int _lfsr = 0;
  int _freq = 0;

  Float32List render(int samples) {
    final buf = Float32List(samples);

    for (int i = 0; i < samples; i++) {
      _counter--;

      if (_counter == 0) {
        _high = !_high;
        _counter = _freq;

        if (_high) {
          final input = periodic ? _lfsr : (_lfsr ^ _lfsr >> 3);
          _lfsr = _lfsr >> 1 | input << 15 & 0x8000;
        }
      }

      buf[i] = _lfsr.bit0 ? _volumeTable[vol] : -_volumeTable[vol];
    }

    return buf;
  }
}

class Sn76489 {
  static const sampleHz = 3579545 ~/ 16; // ntsc: 223kHz

  final tones = [Tone(), Tone(), Tone()];
  final noise = Noise();

  int _latch = 0;

  int elapsedSamples = 0;

  Sn76489();

  Float32List get audioBuffer => Float32List(1000);

  int read8() {
    return 0;
  }

  write8(int value) {
    final ch = (value.bit7 ? value : _latch) >> 5 & 0x03;

    if (value.bit7) {
      if (value.bit4) {
        if (ch == 3) {
          noise.vol = value & 0x0f;
        } else {
          tones[ch].vol = value & 0x0f;
        }
        return;
      }

      _latch = value;
    }

    // noise
    if (ch == 3) {
      noise.periodic = value.bit2;
      noise.shift = value & 0x03;
      return;
    }

    // tone
    if (!value.bit7) {
      tones[ch].freq = (value << 4 & 0x3f0) | _latch & 0x0f;

      if (ch == 2) {
        noise.tone2freq = tones[2].freq;
      }
    }
  }

  void reset() {
    elapsedSamples = 0;
    for (final tone in tones) {
      tone.freq = 0;
      tone.vol = 0;
    }
    noise.vol = 0;
    noise.tone2freq = 0;
    noise.periodic = false;
  }

  // single channel render
  Float32List render(int samples) {
    elapsedSamples += samples;

    final buf = Float32List(samples);

    for (final tone in tones) {
      final wave = tone.render(samples);

      for (int i = 0; i < samples; i++) {
        buf[i] += wave[i] / 4;
      }
    }

    final wave = noise.render(samples);
    for (int i = 0; i < samples; i++) {
      buf[i] += wave[i] / 4;
    }

    return buf;
  }
}
