import 'dart:typed_data';

import '../../util/int.dart';

final _volumeTable = [
  32767, 26028, 20675, 16422, 13045, 10362, 8231, 6568, //
  5193, 4125, 3277, 2603, 2067, 1642, 1304, 0 //
].map((e) => e / 32767).toList();

class Tone {
  int freq = 0;
  int vol = 15;

  int _counter = 0;
  bool _high = false;
  double _vol = 0;

  Float32List render(int samples) {
    final buf = Float32List(samples);
    renderTo(buf, samples);
    return buf;
  }

  /// renders [samples] samples into the head of [buf]
  void renderTo(Float32List buf, int samples) {
    if (freq == 0 || freq == 1) {
      buf.fillRange(0, samples, _volumeTable[vol]);
      return;
    }

    for (int i = 0; i < samples; i++) {
      _counter--;

      if (_counter <= 0) {
        _high = !_high;
        _vol = _high ? _volumeTable[vol] : -_volumeTable[vol];
        _counter = freq;
      }

      buf[i] = _vol;
    }
  }
}

class Noise {
  int vol = 15;
  bool periodic = false;

  int _tone2freq = 0;
  int _shift = 0;

  set tone2freq(int freq) {
    _tone2freq = freq;
    if (_shift == 3) {
      _freq = freq; // follows the tone 2 frequency
    }
  }

  set shift(int s) {
    _shift = s;
    _freq = [0x10, 0x20, 0x40, _tone2freq][s];
    _lfsr = 0x8000;
  }

  int _counter = 0;
  bool _high = false;
  int _lfsr = 0x8000;
  int _freq = 0;
  double _vol = 0;

  Float32List render(int samples) {
    final buf = Float32List(samples);
    renderTo(buf, samples);
    return buf;
  }

  /// renders [samples] samples into the head of [buf]
  void renderTo(Float32List buf, int samples) {
    for (int i = 0; i < samples; i++) {
      _counter--;

      if (_counter <= 0) {
        _high = !_high;
        _counter = _freq;

        if (_high) {
          final input = periodic ? _lfsr : (_lfsr ^ _lfsr.shr3);
          _lfsr = _lfsr.shr1 | input.shl15 & 0x8000;
        }

        _vol = _lfsr.bit0 ? _volumeTable[vol] : -_volumeTable[vol];
      }

      buf[i] = _vol;
    }
  }
}

class Sn76489 {
  int sampleHz = 3579545 ~/ 16; // ntsc: 223kHz
  void setClockHz(int hz) {
    sampleHz = hz ~/ 16;
  }

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
    if (value.bit7) {
      _latch = value;
    }

    final ch = _latch.shr5.mask2;

    // volume: both latch and data bytes update the latched channel
    if (_latch.bit4) {
      if (ch == 3) {
        noise.vol = value.mask4;
      } else {
        tones[ch].vol = value.mask4;
      }
      return;
    }

    // noise
    if (ch == 3) {
      noise.periodic = value.bit2;
      noise.shift = value.mask2;
      return;
    }

    // tone: latch byte updates low 4 bits, data byte updates high 6 bits
    tones[ch].freq = value.bit7
        ? tones[ch].freq & 0x3f0 | value.mask4
        : (value.shl4 & 0x3f0) | tones[ch].freq.mask4;

    if (ch == 2) {
      noise.tone2freq = tones[2].freq;
    }
  }

  void reset() {
    elapsedSamples = 0;
    for (final tone in tones) {
      tone.freq = 0;
      tone.vol = 15;
    }
    noise.vol = 15;
    noise.tone2freq = 0;
    noise.periodic = false;
  }

  // single channel render
  Float32List render(int samples) {
    final buf = Float32List(samples);
    renderTo(buf, 0, samples);
    return buf;
  }

  // work buffers of the channels
  var _wave0 = Float32List(256);
  var _wave1 = Float32List(256);
  var _wave2 = Float32List(256);
  var _wave3 = Float32List(256);

  /// single channel render into [out] from [offset]
  void renderTo(Float32List out, int offset, int samples) {
    elapsedSamples += samples;

    if (_wave0.length < samples) {
      _wave0 = Float32List(samples);
      _wave1 = Float32List(samples);
      _wave2 = Float32List(samples);
      _wave3 = Float32List(samples);
    }
    final wave0 = _wave0, wave1 = _wave1, wave2 = _wave2, wave3 = _wave3;

    tones[0].renderTo(wave0, samples);
    tones[1].renderTo(wave1, samples);
    tones[2].renderTo(wave2, samples);
    noise.renderTo(wave3, samples);

    for (int i = 0; i < samples; i++) {
      out[offset + i] = (wave0[i] + wave1[i] + wave2[i] + wave3[i]) / 4;
    }
  }

  String dump() {
    final tone =
        tones.map((e) => "${e.vol.x2} ${e.freq.x4}").toList().join(" ");
    final n = "${noise.vol.x2} ${noise.periodic ? 1 : 0}";
    return "psg: t:$tone n:$n";
  }
}
