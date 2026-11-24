import '../../util/state.dart';
import 'memory.dart';

/// The envelope curve modes of the ADSR calls.
abstract final class SasCurve {
  static const linearIncrease = 0;
  static const linearDecrease = 1;

  /// A linear increase that slows to a quarter above three quarters.
  static const linearBent = 2;
  static const exponentDecrease = 3;
  static const exponentIncrease = 4;

  /// The rate is the envelope height itself.
  static const direct = 5;
}

class _SasVoice {
  // Sample source: PS-ADPCM (VAG) blocks or noise.
  int vagAt = 0;
  int vagSize = 0;
  int loopMode = 0;
  int noiseFreq = -1;

  int pitch = 0x1000;
  int volumeLeft = 0x1000;
  int volumeRight = 0x1000;

  bool on = false;
  bool paused = false;

  // Decoder: the byte offset of the next block, the loop start, the
  // decoded block and the filter history.
  int blockAt = 0;
  int loopAt = 0;
  final block = List<int>.filled(28, 0);
  int blockIndex = 28;
  bool lastBlock = false;
  int history1 = 0, history2 = 0;
  int previous = 0, current = 0;
  int fraction = 0;
  int noise = 1;
  int noiseCount = 0;

  // Envelope: the height runs from 0 to [PspSas.envelopeMax].
  int height = 0;
  int phase = _phaseOff;
  final rates = List<int>.filled(4, 0);
  final modes = List<int>.filled(4, 0);
  int sustainLevel = PspSas.envelopeMax;

  _SasVoice() {
    reset();
  }

  void reset() {
    on = false;
    paused = false;
    vagAt = 0;
    vagSize = 0;
    loopMode = 0;
    noiseFreq = -1;
    pitch = 0x1000;
    volumeLeft = volumeRight = 0x1000;
    height = 0;
    phase = _phaseOff;
    // Defaults: an instant attack, no decay and sustain at full height,
    // and an instant release. These are assumptions; games set the
    // envelope before they key a voice on.
    rates.setAll(0, [0x7fffffff, 0, 0, 0x7fffffff]);
    modes.setAll(0, [
      SasCurve.linearIncrease,
      SasCurve.exponentDecrease,
      SasCurve.linearIncrease,
      SasCurve.linearDecrease
    ]);
    sustainLevel = PspSas.envelopeMax;
  }

  static const _phaseAttack = 0,
      _phaseDecay = 1,
      _phaseSustain = 2,
      _phaseRelease = 3,
      _phaseOff = 4;
}

/// The sceSasCore software synthesizer: up to 32 voices that play
/// PS-ADPCM (VAG) data or noise at a pitch, shaped by an ADSR envelope
/// and mixed into one grain of 16-bit stereo samples per call.
///
/// The ADPCM format follows the public description of the PlayStation
/// sound format: 16-byte blocks of a shift and filter byte, a flag byte
/// and 28 four-bit samples. The simple ADSR form uses the bit layout of
/// the PlayStation sound processor's envelope registers. Reverb is not
/// emulated: its calls are accepted and the effect send is dropped.
class PspSas {
  final PspMemory mem;

  static const envelopeMax = 0x40000000;
  static const voiceCount = 32;
  static const errorVoice = 0x80420010;

  int grain = 256;
  int maxVoices = voiceCount;
  int outputMode = 0;
  final _voices = List.generate(voiceCount, (_) => _SasVoice());

  PspSas(this.mem);

  static const _filters = [
    [0, 0],
    [60, 0],
    [115, -52],
    [98, -55],
    [122, -60],
  ];

  int init(int grainSamples, int voices, int mode) {
    grain = grainSamples.clamp(0x40, 0x800);
    maxVoices = voices.clamp(1, voiceCount);
    outputMode = mode;
    for (final voice in _voices) {
      voice.reset();
    }
    return 0;
  }

  _SasVoice? _voice(int index) =>
      index >= 0 && index < voiceCount ? _voices[index] : null;

  int setVoice(int index, int at, int size, int loopMode) {
    final voice = _voice(index);
    if (voice == null) return errorVoice;
    voice.vagAt = at;
    voice.vagSize = size;
    voice.loopMode = loopMode;
    voice.noiseFreq = -1;
    return 0;
  }

  int setNoise(int index, int freq) {
    final voice = _voice(index);
    if (voice == null) return errorVoice;
    voice.noiseFreq = freq & 0x3f;
    return 0;
  }

  int setPitch(int index, int pitch) {
    final voice = _voice(index);
    if (voice == null) return errorVoice;
    voice.pitch = pitch.clamp(0, 0x4000);
    return 0;
  }

  int setVolume(int index, int left, int right) {
    final voice = _voice(index);
    if (voice == null) return errorVoice;
    voice.volumeLeft = left.toSigned(32);
    voice.volumeRight = right.toSigned(32);
    return 0;
  }

  int keyOn(int index) {
    final voice = _voice(index);
    if (voice == null) return errorVoice;
    voice
      ..on = true
      ..paused = false
      ..blockAt = 0
      ..loopAt = 0
      ..blockIndex = 28
      ..lastBlock = false
      ..history1 = 0
      ..history2 = 0
      ..previous = 0
      ..current = 0
      ..fraction = 0
      ..height = 0
      ..phase = _SasVoice._phaseAttack;
    return 0;
  }

  int keyOff(int index) {
    final voice = _voice(index);
    if (voice == null) return errorVoice;
    if (voice.on) voice.phase = _SasVoice._phaseRelease;
    return 0;
  }

  /// Sets the rates of the envelope parts whose bits are set in [flags]
  /// (1 attack, 2 decay, 4 sustain, 8 release).
  int setAdsr(int index, int flags, List<int> rates) {
    final voice = _voice(index);
    if (voice == null) return errorVoice;
    for (var i = 0; i < 4; i++) {
      if (flags & (1 << i) != 0) voice.rates[i] = rates[i] & 0x7fffffff;
    }
    return 0;
  }

  int setAdsrMode(int index, int flags, List<int> modes) {
    final voice = _voice(index);
    if (voice == null) return errorVoice;
    for (var i = 0; i < 4; i++) {
      if (flags & (1 << i) != 0) voice.modes[i] = modes[i] & 7;
    }
    return 0;
  }

  int setSustainLevel(int index, int level) {
    final voice = _voice(index);
    if (voice == null) return errorVoice;
    voice.sustainLevel = level.clamp(0, envelopeMax);
    return 0;
  }

  /// Sets the envelope from the two 16-bit words of the PlayStation sound
  /// processor's ADSR register layout.
  int setSimpleAdsr(int index, int env1, int env2) {
    final voice = _voice(index);
    if (voice == null) return errorVoice;
    voice.modes[0] =
        env1 & 0x8000 != 0 ? SasCurve.linearBent : SasCurve.linearIncrease;
    voice.rates[0] = _spuRate((env1 >> 8) & 0x7f, increase: true);
    voice.modes[1] = SasCurve.exponentDecrease;
    voice.rates[1] = _spuRate(((env1 >> 4) & 0xf) * 4, increase: false);
    voice.sustainLevel = ((env1 & 0xf) + 1) * (envelopeMax >> 4);
    final sustainDown = env2 & 0x4000 != 0;
    final sustainExp = env2 & 0x8000 != 0;
    voice.modes[2] = sustainDown
        ? (sustainExp ? SasCurve.exponentDecrease : SasCurve.linearDecrease)
        : (sustainExp ? SasCurve.linearBent : SasCurve.linearIncrease);
    voice.rates[2] = _spuRate((env2 >> 6) & 0x7f, increase: !sustainDown);
    voice.modes[3] =
        env2 & 0x20 != 0 ? SasCurve.exponentDecrease : SasCurve.linearDecrease;
    voice.rates[3] = _spuRate((env2 & 0x1f) * 4, increase: false);
    return 0;
  }

  /// The per-sample change of a sound processor envelope rate, scaled
  /// from its 15-bit level to the height range: a step of 7 - (rate & 3)
  /// (increase) or 8 - (rate & 3) (decrease) shifted by 11 - rate / 4.
  static int _spuRate(int rate, {required bool increase}) {
    final step = increase ? 7 - (rate & 3) : 8 - (rate & 3);
    final shift = 26 - (rate >> 2);
    return shift >= 0 ? step << shift : step >> -shift;
  }

  /// The paused voices, one bit per voice.
  int get pauseFlags {
    var flags = 0;
    for (var i = 0; i < voiceCount; i++) {
      if (_voices[i].paused) flags |= 1 << i;
    }
    return flags;
  }

  /// Pauses or resumes the voices whose bits are set in [voices].
  int setPause(int voices, bool pause) {
    for (var i = 0; i < voiceCount; i++) {
      if (voices & (1 << i) != 0) _voices[i].paused = pause;
    }
    return 0;
  }

  int setGrain(int samples) {
    grain = samples.clamp(0x40, 0x800);
    return 0;
  }

  int envelopeHeight(int index) => _voice(index)?.height ?? errorVoice;

  /// The voices that do not play, one bit per voice.
  int get endFlags {
    var flags = 0;
    for (var i = 0; i < voiceCount; i++) {
      if (!_voices[i].on) flags |= 1 << i;
    }
    return flags;
  }

  /// Mixes one grain into the stereo 16-bit buffer at [outAt]. With
  /// [mixLeft] and [mixRight], the samples already in the buffer are
  /// scaled by those volumes (0x1000 is unity) and the voices add to
  /// them.
  void mix(int outAt, {int? mixLeft, int? mixRight}) {
    final left = List<int>.filled(grain, 0);
    final right = List<int>.filled(grain, 0);
    for (var i = 0; i < maxVoices; i++) {
      final voice = _voices[i];
      if (!voice.on || voice.paused) continue;
      for (var n = 0; n < grain; n++) {
        final sample = _nextSample(voice);
        if (!voice.on) break;
        final scaled = (sample * voice.height) >> 30;
        left[n] += (scaled * voice.volumeLeft) >> 12;
        right[n] += (scaled * voice.volumeRight) >> 12;
      }
    }
    for (var n = 0; n < grain; n++) {
      var l = left[n], r = right[n];
      if (mixLeft != null) {
        l += (mem.read16(outAt + n * 4).toSigned(16) * mixLeft) >> 12;
        r += (mem.read16(outAt + n * 4 + 2).toSigned(16) * mixRight!) >> 12;
      }
      mem.write16(outAt + n * 4, l.clamp(-0x8000, 0x7fff) & 0xffff);
      mem.write16(outAt + n * 4 + 2, r.clamp(-0x8000, 0x7fff) & 0xffff);
    }
  }

  /// The next output sample of [voice] at its pitch, interpolated
  /// linearly between source samples, after one envelope step.
  int _nextSample(_SasVoice voice) {
    voice.fraction += voice.pitch;
    while (voice.fraction >= 0x1000) {
      voice.fraction -= 0x1000;
      voice.previous = voice.current;
      voice.current = _sourceSample(voice);
      if (!voice.on) return 0;
    }
    _stepEnvelope(voice);
    return voice.previous +
        (((voice.current - voice.previous) * voice.fraction) >> 12);
  }

  int _sourceSample(_SasVoice voice) {
    if (voice.noiseFreq >= 0) {
      // A 15-bit shift register clocked faster at higher frequencies.
      final hold = 1 << ((0x3f - voice.noiseFreq) >> 2);
      if (++voice.noiseCount >= hold) {
        voice.noiseCount = 0;
        final bit = (voice.noise ^ (voice.noise >> 1)) & 1;
        voice.noise = (voice.noise >> 1) | (bit << 14);
      }
      return voice.noise & 1 != 0 ? 0x7fff : -0x8000;
    }
    if (voice.blockIndex >= 28) {
      if (voice.lastBlock || !_decodeBlock(voice)) {
        voice.on = false;
        voice.phase = _SasVoice._phaseOff;
        voice.height = 0;
        return 0;
      }
    }
    return voice.block[voice.blockIndex++];
  }

  /// Decodes the next block of [voice]; false when the data has ended.
  bool _decodeBlock(_SasVoice voice) {
    if (voice.blockAt + 16 > voice.vagSize) {
      if (voice.loopMode == 0) return false;
      voice.blockAt = voice.loopAt;
      if (voice.blockAt + 16 > voice.vagSize) return false;
    }
    final at = voice.vagAt + voice.blockAt;
    final header = mem.read8(at);
    final flags = mem.read8(at + 1);
    if (flags == 7) return false;
    if (flags & 4 != 0) voice.loopAt = voice.blockAt;
    final shift = header & 0xf;
    final filter = _filters[((header >> 4) & 0xf).clamp(0, 4)];
    for (var i = 0; i < 28; i++) {
      final byte = mem.read8(at + 2 + (i >> 1));
      final nibble = (i & 1 == 0 ? byte & 0xf : byte >> 4);
      final raw = ((nibble << 28).toSigned(32)) >> (16 + shift);
      final value = raw +
          ((voice.history1 * filter[0] + voice.history2 * filter[1] + 32) >> 6);
      final sample = value.clamp(-0x8000, 0x7fff);
      voice.block[i] = sample;
      voice.history2 = voice.history1;
      voice.history1 = sample;
    }
    voice.blockIndex = 0;
    voice.blockAt += 16;
    if (flags & 1 != 0) {
      // The end of the data: repeat from the loop start when the block
      // asks for it or the voice was set to loop.
      if (flags & 2 != 0 || voice.loopMode != 0) {
        voice.blockAt = voice.loopAt;
      } else {
        voice.lastBlock = true;
      }
    }
    return true;
  }

  void _stepEnvelope(_SasVoice voice) {
    final phase = voice.phase;
    if (phase >= _SasVoice._phaseOff) return;
    final mode = voice.modes[phase];
    final rate = voice.rates[phase];
    var h = voice.height;
    switch (mode) {
      case SasCurve.linearIncrease:
        h += rate;
      case SasCurve.linearDecrease:
        h -= rate;
      case SasCurve.linearBent:
        h += h < envelopeMax * 3 ~/ 4 ? rate : rate >> 2;
      case SasCurve.exponentDecrease:
        final step = (rate * h) >> 30;
        h -= step > 0 || rate == 0 ? step : 1;
      case SasCurve.exponentIncrease:
        final step = (rate * (envelopeMax - h)) >> 30;
        h += step > 0 || rate == 0 ? step : 1;
      case SasCurve.direct:
        h = rate;
    }
    switch (phase) {
      case _SasVoice._phaseAttack:
        if (h >= envelopeMax) {
          h = envelopeMax;
          voice.phase = _SasVoice._phaseDecay;
        }
      case _SasVoice._phaseDecay:
        if (h <= voice.sustainLevel) {
          h = voice.sustainLevel;
          voice.phase = _SasVoice._phaseSustain;
        }
      case _SasVoice._phaseSustain:
        h = h.clamp(0, envelopeMax);
      case _SasVoice._phaseRelease:
        if (h <= 0) {
          h = 0;
          voice.on = false;
          voice.phase = _SasVoice._phaseOff;
        }
    }
    voice.height = h.clamp(0, envelopeMax);
  }

  void saveState(StateWriter writer) {
    writer.section('sas');
    writer.int32(grain);
    writer.int32(maxVoices);
    writer.int32(outputMode);
    for (final v in _voices) {
      writer.ints([
        v.vagAt, v.vagSize, v.loopMode, v.noiseFreq, v.pitch, //
        v.volumeLeft, v.volumeRight, v.on ? 1 : 0, v.paused ? 1 : 0,
        v.blockAt, v.loopAt, v.blockIndex, v.lastBlock ? 1 : 0,
        v.history1, v.history2, v.previous, v.current, v.fraction,
        v.noise, v.noiseCount, v.height, v.phase, v.sustainLevel,
        ...v.rates, ...v.modes, ...v.block,
      ]);
    }
  }

  void loadState(StateReader reader) {
    reader.section('sas');
    grain = reader.int32();
    maxVoices = reader.int32();
    outputMode = reader.int32();
    for (final v in _voices) {
      final x = reader.ints();
      var i = 0;
      v
        ..vagAt = x[i++]
        ..vagSize = x[i++]
        ..loopMode = x[i++]
        ..noiseFreq = x[i++]
        ..pitch = x[i++]
        ..volumeLeft = x[i++]
        ..volumeRight = x[i++]
        ..on = x[i++] != 0
        ..paused = x[i++] != 0
        ..blockAt = x[i++]
        ..loopAt = x[i++]
        ..blockIndex = x[i++]
        ..lastBlock = x[i++] != 0
        ..history1 = x[i++]
        ..history2 = x[i++]
        ..previous = x[i++]
        ..current = x[i++]
        ..fraction = x[i++]
        ..noise = x[i++]
        ..noiseCount = x[i++]
        ..height = x[i++]
        ..phase = x[i++]
        ..sustainLevel = x[i++];
      for (var k = 0; k < 4; k++) {
        v.rates[k] = x[i++];
      }
      for (var k = 0; k < 4; k++) {
        v.modes[k] = x[i++];
      }
      for (var k = 0; k < 28; k++) {
        v.block[k] = x[i++];
      }
    }
  }
}
