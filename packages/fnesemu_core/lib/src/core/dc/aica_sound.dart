import 'dart:math' as math;
import 'dart:typed_data';

import '../../state.dart';
import '../../types.dart';
import '../../util/int.dart';
import '../../util/uint8list.dart';
import 'aica_adpcm_stream.dart';
import 'aica_dsp.dart';
import 'aica_feg.dart';
import 'aica_filter.dart';
import 'aica_lfo.dart';
import 'aica_noise.dart';
import 'fault.dart';

/// Functional AICA source/mixer model from System Architecture §8.1.1/8.4.5.
/// Envelope curves, interpolation rounding and DAC arithmetic need hardware tests.
class DcAicaSound {
  DcAicaSound(this.memory, {required this.dsp});
  final DcAicaDsp dsp;
  // Explicit bring-up interpretation of the AICA manual's byte-addressed SA.
  // System Architecture instead requires four-byte ADPCM alignment.
  bool diagnosticByteAddressAdpcm = false;
  // Explicit opt-in: the original manuals do not specify the filter coefficients.
  bool diagnosticFilterApproximation = false;
  final _effectControls = Uint16List(18);
  int _effectCount = 0;
  final _dspMix = Float64List(16);
  static bool outputRegister(int offset) =>
      offset >= 0x2000 && offset <= 0x2044;
  int readOutput(int offset) => _effectControls[(offset - 0x2000) ~/ 4];
  void writeOutput(int offset, int value) {
    final index = (offset - 0x2000) ~/ 4;
    if (_effectControls[index] & 0xf00 != 0) _effectCount--;
    _effectControls[index] = value & 0x0f1f;
    if (_effectControls[index] & 0xf00 != 0) _effectCount++;
  }

  bool get needsSampleClock {
    if (active || dsp.hasProgram || dsp.hasMix || dsp.hasPendingMemory) {
      return true;
    }
    if (_effectCount == 0) return false;
    for (var effect = 0; effect < 18; effect++) {
      if (_effectControls[effect] & 0xf00 != 0 && dsp.output(effect) != 0) {
        return true;
      }
    }
    return false;
  }

  // SSCTL noise uses an internal source rather than a wave-RAM fetch.
  bool get readsWaveMemory =>
      _slots.any((voice) => voice.active && !voice.noiseSelected);

  static const sampleRate = 44100, fraction = 1 << 18, packetFrames = 256;
  final Uint8List memory;
  final _slots = List.generate(64, (index) => _Voice(index));
  int control = 0, monitor = 0;
  void Function(AudioBuffer)? _onAudio;
  Float32List _output = Float32List(packetFrames * 2);
  int _outputPosition = 0;
  int _activeCount = 0, _sampleClock = 0;

  bool get active => _activeCount != 0;
  void setAudio(void Function(AudioBuffer) callback) {
    _onAudio = callback;
    _outputPosition = 0;
  }

  void reset() {
    for (final voice in _slots) {
      voice.reset();
    }
    _effectControls.fillRange(0, _effectControls.length, 0);
    _effectCount = 0;
    _dspMix.fillRange(0, _dspMix.length, 0);
    control = monitor = _outputPosition = 0;
    _activeCount = _sampleClock = 0;
    _output = Float32List(packetFrames * 2);
  }

  /// Wave RAM and DSP state are separate sections owned by AICA.
  /// The pending audio prefix is logical mixer state; the host callback is not.
  void saveState(StateWriter writer) {
    writer.section('dc.aica.sound');
    writer.int32(control);
    writer.int32(monitor);
    writer.int64(_sampleClock);
    writer.int32(_outputPosition);
    writer.floats(_output);
    writer.ints(_effectControls);
    for (final voice in _slots) {
      voice.saveState(writer);
    }
  }

  void loadState(StateReader reader) {
    reader.section('dc.aica.sound');
    final volume = reader.int32(), selection = reader.int32();
    final clock = reader.int64(), position = reader.int32();
    final output = reader.floats(), effects = reader.ints();
    final voices = [
      for (var i = 0; i < 64; i++) _Voice.fromState(i, memory, reader)
    ];
    if (volume & ~0x810f != 0 ||
        selection & ~0x7f00 != 0 ||
        clock < 0 ||
        position < 0 ||
        position >= _output.length ||
        position.isOdd ||
        output.length != _output.length ||
        output.any((sample) => !sample.isFinite || sample < -1 || sample > 1) ||
        effects.length != _effectControls.length ||
        effects.any((value) => value & ~0x0f1f != 0)) {
      throw const StateMismatch('AICA sound mixer state');
    }
    for (final voice in voices) {
      if (voice.active) {
        try {
          _validate(voice);
        } on DcUnsupported {
          throw const StateMismatch('AICA active voice state');
        }
      }
    }
    control = volume;
    monitor = selection;
    _sampleClock = clock;
    _outputPosition = position;
    _output.setAll(0, output);
    _effectControls.setAll(0, effects);
    _slots.setAll(0, voices);
    _activeCount = voices.where((voice) => voice.active).length;
    _effectCount = effects.where((value) => value & 0xf00 != 0).length;
    _dspMix.fillRange(0, _dspMix.length, 0);
  }

  static bool channelRegister(int offset) =>
      offset >= 0 && offset < 0x2000 && offset & 0x7f <= 0x44;

  int read(int offset) => _slots[offset ~/ 0x80].regs[(offset & 0x7f) ~/ 4];
  void write(int offset, int value) {
    final voice = _slots[offset ~/ 0x80], index = (offset & 0x7f) ~/ 4;
    final mask = switch (index) {
      0 => 0x47ff,
      4 => 0xffdf,
      5 => 0x7fff,
      6 => 0x7bff,
      8 => 0xff,
      9 => 0xf1f,
      10 => 0xff1f,
      >= 11 && <= 15 => 0x1fff,
      16 || 17 => 0x1f1f,
      _ => 0xffff,
    };
    final previous = voice.regs[index];
    voice.regs[index] = value & mask;
    final sourceChanged = index <= 3 &&
        (index == 0
            // LPCTL changes loop policy without replacing the ADPCM source.
            ? (previous & 0x400 != 0 && voice.noiseSelected
                ? false
                : (previous ^ voice.regs[0]) & 0x5ff != 0)
            : (index != 1 || !voice.noiseSelected) &&
                previous != voice.regs[index]);
    final retireSource = voice.active &&
        sourceChanged &&
        (voice.state == 3 || control & 15 == 0);
    try {
      if (voice.active && !retireSource) {
        final wasNoise =
            index == 0 ? previous & 0x400 != 0 : voice.noiseSelected;
        final wasAdpcm = !wasNoise &&
            (index == 0
                ? (previous >> 7) & 3 >= 2
                : (voice.regs[0] >> 7) & 3 >= 2);
        final isAdpcm = !voice.noiseSelected && (voice.regs[0] >> 7) & 3 >= 2;
        if ((wasAdpcm || isAdpcm) && sourceChanged) {
          throw DcUnsupported(
              'AICA ADPCM source changes during playback: slot=${voice.slot} '
              'register=$index previous=${previous.toRadixString(16)} '
              'value=${voice.regs[index].toRadixString(16)} '
              'state=${voice.state} control=${voice.regs[0].toRadixString(16)} '
              'phase=${voice.phase ~/ fraction}');
        }
        _validate(voice);
      }
      if (index == 0 && value & 0x8000 != 0) {
        for (final slot in _slots) {
          if (slot.regs[0] & 0x4000 != 0 &&
              (slot.state == 3 || (identical(slot, voice) && retireSource))) {
            _validate(slot);
          }
        }
      }
    } on DcUnsupported {
      voice.regs[index] = previous;
      rethrow;
    }
    if (retireSource) {
      // The game reuses channels under master mute or after key-off, before the release envelope has finished.
      // Provisionally retire the old decoder instead of applying new source registers to its history.
      // Held ADPCM voices still reject source replacement; precise release tails are pending.
      voice.active = false;
      voice.state = 3;
      voice.stream = null;
      voice.noise = null;
      voice.decoded = null;
      _activeCount--;
    }
    if (voice.active && voice.noiseSelected) {
      voice.noise ??= DcAicaNoise(voice.slot);
      voice.stream = null;
      voice.decoded = null;
    } else if (!voice.noiseSelected) {
      voice.noise = null;
    }
    if (index == 7) voice.lfo.write(_sampleClock, previous, voice.regs[7]);
    if (index == 0 && value & 0x8000 != 0) {
      for (final slot in _slots) {
        if (slot.regs[0] & 0x4000 != 0) {
          // A naturally exhausted one-shot retains its last key-on state.
          // Re-arm it through key-off before a later global key-on strobe.
          if (slot.state == 3) {
            if (!slot.active) _activeCount++;
            slot.start(memory);
          }
        } else if (slot.state != 3) {
          slot.feg.release(slot.regs[14]);
          slot.state = 3;
        }
      }
    }
  }

  void _validate(_Voice voice) {
    final regs = voice.regs, format = (regs[0] >> 7) & 3;
    if (voice.noiseSelected) {
      if (regs[2] > regs[3] || (voice.loop && regs[2] == regs[3])) {
        throw const DcUnsupported('AICA invalid loop interval');
      }
      if (voice.active && voice.phase ~/ fraction > regs[3]) {
        throw const DcUnsupported('AICA end address precedes active position');
      }
      return;
    }
    if (format == 3 && (regs[2] | regs[3]) & 3 != 0) {
      throw const DcUnsupported('AICA ADPCM long-stream loop alignment');
    }
    if (voice.startAddress &
            (format == 0
                ? 1
                : format >= 2
                    ? (format == 2 && diagnosticByteAddressAdpcm ? 0 : 3)
                    : 0) !=
        0) {
      throw DcUnsupported('AICA source address alignment: slot=${voice.slot} '
          'format=$format address=${voice.startAddress.toRadixString(16)} '
          'active=${voice.active} state=${voice.state} '
          'control=${regs[0].toRadixString(16)}');
    }
    if (regs[2] > regs[3] || (voice.loop && regs[2] == regs[3])) {
      throw const DcUnsupported('AICA invalid loop interval');
    }
    if (voice.active && voice.phase ~/ fraction > regs[3]) {
      throw const DcUnsupported('AICA end address precedes active position');
    }
    final bytes = format == 0
        ? (regs[3] + 1) * 2
        : format == 1
            ? regs[3] + 1
            : regs[3] ~/ 2 + 1;
    if (voice.startAddress + bytes > memory.length) {
      throw const DcUnsupported('AICA source exceeds retail wave memory');
    }
  }

  int readMonitor({bool sideEffects = true}) {
    final voice = _slots[(monitor >> 8) & 63];
    final value = monitor & 0x4000 != 0
        ? (voice.feg.state << 13) | voice.feg.level.round().clamp(0, 8191)
        : (voice.looped ? 0x8000 : 0) |
            (voice.state << 13) |
            voice.attenuation.round().clamp(0, 1023);
    if (sideEffects) voice.looped = false;
    return value;
  }

  int get currentAddress => _slots[(monitor >> 8) & 63].phase ~/ fraction;

  static final _sends = Float64List.fromList([
    for (var value = 0; value < 16; value++)
      value == 0 ? 0 : math.pow(10, -3 * (15 - value) / 20).toDouble()
  ]);
  static final _pans = Float64List.fromList([
    for (var value = 0; value < 16; value++)
      value == 15 ? 0 : math.pow(10, -3 * value / 20).toDouble()
  ]);
  static final _levels = Float64List.fromList(
      [for (var value = 0; value < 256; value++) _levelGain(value)]);

  /// Envelope gains at whole attenuation steps, with one entry past the end
  /// for interpolation.
  static final _envelopeGains = Float64List.fromList([
    for (var step = 0; step <= 1024; step++)
      math.pow(10, -96 * step / (1023 * 20)).toDouble()
  ]);

  static double _send(int value) => _sends[value];
  static double _pan(int value) => _pans[value];
  static double _level(int value) => _levels[value];
  static double _levelGain(int value) {
    const weights = [0.4, 0.8, 1.5, 3.0, 6.0, 12.0, 24.0, 48.0];
    var db = 0.0;
    for (var bit = 0; bit < 8; bit++) {
      if (value & (1 << bit) != 0) db += weights[bit];
    }
    return math.pow(10, -db / 20).toDouble();
  }

  /// The gain of an attenuation in 0 to 1023, interpolated between steps.
  static double envelopeGain(double attenuation) {
    final step = attenuation.toInt(), low = _envelopeGains[step];
    return low + (_envelopeGains[step + 1] - low) * (attenuation - step);
  }

  void advance(int samples,
      {void Function()? beforeSample, bool dspMemoryInhibited = false}) {
    if (beforeSample == null && !needsSampleClock && _onAudio == null) {
      dsp.advanceSamples(samples);
      _sampleClock += samples;
      return;
    }
    for (var frame = 0; frame < samples; frame++) {
      dsp.validateSample(memoryInhibited: dspMemoryInhibited);
      beforeSample?.call();
      _dspMix.fillRange(0, 16, 0);
      var left = 0.0, right = 0.0;
      for (final voice in _slots) {
        if (!voice.active) continue;
        _envelope(voice);
        if (!voice.active) {
          _activeCount--;
          continue;
        }
        final regs = voice.regs;
        voice.feg.advance(regs);
        final index = voice.phase ~/ fraction;
        if (index > regs[3]) {
          throw const DcUnsupported(
              'AICA live end-address change crossed source position');
        }
        final next = index < regs[3]
            ? index + 1
            : voice.loop
                ? regs[2] + 1
                : index;
        final a = _source(voice, index);
        // Continuous inputs advance even when a one-sample loop maps back to the same index.
        final lookahead = voice.loop || index < regs[3] ? 1 : 0;
        final b = voice.noise != null
            ? voice.noise!.sample(voice.streamBase + index + lookahead)
            : voice.stream != null
                ? voice.stream!.sample(voice.streamBase + index + lookahead)
                : _source(voice, next);
        var amplitudeLfo = 0, pitchLfo = 0;
        if (regs[7] & 0xe7 != 0) {
          final values = voice.lfo.sample(_sampleClock, regs[7]);
          amplitudeLfo = values.$1;
          pitchLfo = values.$2;
        }
        final raw = a + (b - a) * (voice.phase % fraction) / fraction;
        final filtered = diagnosticFilterApproximation
            ? voice.filter.process(raw, voice.feg.level, regs[10] & 31)
            : raw;
        final source = filtered /
            32768 *
            envelopeGain(voice.attenuation) *
            _level(regs[10] >> 8) *
            DcAicaLfo.amplitudeGain(regs[7] & 7, amplitudeLfo);
        _dspMix[regs[8] & 15] += source * _send((regs[8] >> 4) & 15);
        final value = source * _send((regs[9] >> 8) & 15);
        final pan = control & 0x8000 != 0 ? 0 : regs[9] & 31;
        left += value * (pan < 16 ? _pan(pan) : 1);
        right += value * (pan >= 16 ? _pan(pan & 15) : 1);
        voice.phase +=
            DcAicaLfo.pitchStep(regs[6], (regs[7] >> 5) & 7, pitchLfo);
        if (voice.phase ~/ fraction > regs[3]) {
          if (voice.loop) {
            final period = regs[3] - regs[2];
            voice.streamBase += ((voice.phase - (regs[3] + 1) * fraction) ~/
                        (period * fraction) +
                    1) *
                period;
            voice.phase = (regs[2] + 1) * fraction +
                (voice.phase - (regs[3] + 1) * fraction) % (period * fraction);
            voice.looped = true;
          } else {
            voice.phase = regs[3] * fraction;
            voice.active = false;
            _activeCount--;
          }
        }
      }
      dsp.latchMix(_dspMix);
      dsp.executeSample(memory);
      for (var effect = 0; effect < 18; effect++) {
        final settings = _effectControls[effect];
        if (settings & 0xf00 == 0) continue;
        final value = dsp.output(effect) / 32768 * _send((settings >> 8) & 15);
        final pan = control & 0x8000 != 0 ? 0 : settings & 31;
        left += value * (pan < 16 ? _pan(pan) : 1);
        right += value * (pan >= 16 ? _pan(pan & 15) : 1);
      }
      dsp.advanceSamples(1);
      _sampleClock++;
      if (_onAudio != null) {
        final gain = _send(control & 15);
        final upper = control & 0x100 != 0 ? 131071 / 131072 : 32767 / 32768;
        _output[_outputPosition++] = (left * gain).clamp(-1.0, upper);
        _output[_outputPosition++] = (right * gain).clamp(-1.0, upper);
        if (_outputPosition == _output.length) {
          final packet = _output;
          _output = Float32List(packetFrames * 2);
          _outputPosition = 0;
          _onAudio!(AudioBuffer(sampleRate, 2, packet));
        }
      }
    }
  }

  int _source(_Voice voice, int index) {
    if (voice.noise != null) {
      return voice.noise!.sample(voice.streamBase + index);
    }
    final format = (voice.regs[0] >> 7) & 3, start = voice.startAddress;
    if (format == 0) return memory.getUint16LE(start + index * 2).rel16;
    if (format == 1) return memory[start + index].rel8 * 256;
    if (format == 3) return voice.stream!.sample(voice.streamBase + index);
    const factors = [230, 230, 230, 230, 307, 409, 512, 614];
    final decoded = voice.decoded!;
    while (voice.decodedIndex < index) {
      final position = ++voice.decodedIndex;
      final nibble =
          (memory[start + position ~/ 2] >> ((position & 1) * 4)) & 15;
      final delta = ((2 * (nibble & 7) + 1) * voice.quantization) ~/ 8;
      voice.predictor = (voice.predictor + (nibble & 8 != 0 ? -delta : delta))
          .clamp(-32768, 32767);
      voice.quantization =
          (voice.quantization * factors[nibble & 7] ~/ 256).clamp(127, 24576);
      decoded[position] = voice.predictor;
    }
    return decoded[index];
  }

  void _envelope(_Voice voice) {
    final regs = voice.regs;
    final rate = switch (voice.state) {
      0 => regs[4] & 31,
      1 => (regs[4] >> 6) & 31,
      2 => (regs[4] >> 11) & 31,
      _ => regs[5] & 31,
    };
    final krs = (regs[5] >> 10) & 15;
    final octave = ((regs[6] >> 11) & 15) ^ 8;
    final effective = (rate * 2 +
            (krs == 15 ? 0 : 2 * (krs + octave - 8) + ((regs[6] >> 9) & 1)))
        .clamp(0, 63);
    final time = (voice.state == 0 ? _attack : _decay)[effective];
    if (voice.state == 0) {
      if (time == 0) {
        voice.attenuation = 0;
      } else if (time.isFinite) {
        voice.attenuation =
            math.max(0, voice.attenuation - 1023 * 1000 / (time * sampleRate));
      }
      final linked = regs[5] & 0x4000 != 0;
      if (voice.attenuation == 0 &&
          (!linked || voice.phase ~/ fraction > regs[2])) {
        voice.state = 1;
      }
    } else {
      if (time.isFinite) {
        voice.attenuation = math.min(
            1023, voice.attenuation + 1023 * 1000 / (time * sampleRate));
      }
      if (voice.state == 1 && voice.attenuation >= ((regs[5] >> 5) & 31) * 32) {
        voice.state = 2;
      }
      if (voice.attenuation >= 1023) voice.active = false;
    }
  }

  // Published end-to-end times use a functional linear-dB approximation between envelope codes, not a recovered hardware rate table.
  static const _attack = <double>[
    double.infinity,
    double.infinity,
    8100,
    6900,
    6000,
    4800,
    4000,
    3400,
    3000,
    2400,
    2000,
    1700,
    1500,
    1200,
    1000,
    860,
    760,
    600,
    500,
    430,
    380,
    300,
    250,
    220,
    190,
    150,
    130,
    110,
    95,
    76,
    63,
    55,
    47,
    38,
    31,
    27,
    24,
    19,
    15,
    13,
    12,
    9.4,
    7.9,
    6.8,
    6,
    4.7,
    3.8,
    3.4,
    3,
    2.4,
    2,
    1.8,
    1.6,
    1.3,
    1.1,
    0.93,
    0.85,
    0.65,
    0.53,
    0.44,
    0.4,
    0.35,
    0,
    0,
  ];
  static const _decay = <double>[
    double.infinity,
    double.infinity,
    118200,
    101300,
    88600,
    70900,
    59100,
    50700,
    44300,
    35500,
    29600,
    25300,
    22200,
    17700,
    14800,
    12700,
    11100,
    8900,
    7400,
    6300,
    5500,
    4400,
    3700,
    3200,
    2800,
    2200,
    1800,
    1600,
    1400,
    1100,
    920,
    790,
    690,
    550,
    460,
    390,
    340,
    270,
    230,
    200,
    170,
    140,
    110,
    98,
    85,
    68,
    57,
    49,
    43,
    34,
    28,
    25,
    22,
    18,
    14,
    12,
    11,
    8.5,
    7.1,
    6.1,
    5.4,
    4.3,
    3.6,
    3.1,
  ];
}

class _Voice {
  _Voice(this.slot)
      : lfo = DcAicaLfo(seed: (0x6d2b79f5 ^ ((slot + 1) * 40503)) & 0xffffffff);
  final int slot;
  final DcAicaLfo lfo;
  final feg = DcAicaFeg();
  final filter = DcAicaFilter();
  final regs = Uint16List(18);
  bool active = false, looped = false;
  int phase = 0, state = 3;
  double attenuation = 1023;
  Int16List? decoded;
  DcAicaAdpcmStream? stream;
  DcAicaNoise? noise;
  int streamBase = 0;
  int decodedIndex = -1, predictor = 0, quantization = 127;
  bool get loop => regs[0] & 0x200 != 0;
  bool get noiseSelected => regs[0] & 0x400 != 0;
  int get startAddress => ((regs[0] & 127) << 16) | regs[1];
  void reset() {
    lfo.reset();
    feg.reset();
    filter.reset();
    regs.fillRange(0, 18, 0);
    active = looped = false;
    phase = 0;
    state = 3;
    attenuation = 1023;
    decoded = null;
    stream = null;
    noise = null;
    streamBase = 0;
  }

  void saveState(StateWriter writer) {
    writer.section('dc.aica.voice');
    writer.int32(slot);
    writer.ints(regs);
    final history = filter.z1 != 0 || filter.z2 != 0;
    final extra = (history ? 1 : 0) | (noise != null ? 2 : 0);
    writer.ints([
      phase,
      state,
      streamBase,
      decodedIndex,
      predictor,
      quantization,
      if (extra != 0) extra
    ]);
    if (history) writer.floats([filter.z1, filter.z2]);
    noise?.saveState(writer);
    writer.boolean(active);
    writer.boolean(looped);
    writer.float64(attenuation);
    lfo.saveState(writer);
    feg.saveState(writer);
    writer.boolean(decoded != null);
    if (decoded != null) writer.ints(decoded!);
    writer.boolean(stream != null);
    stream?.saveState(writer);
  }

  factory _Voice.fromState(int slot, Uint8List memory, StateReader reader) {
    reader.section('dc.aica.voice');
    final index = reader.int32(),
        registers = reader.ints(),
        values = reader.ints();
    final extra = values.length == 7 ? values[6] : 0;
    final history = extra & 1 != 0 ? reader.floats() : null;
    final noise = extra & 2 != 0 ? DcAicaNoise.fromState(reader) : null;
    final active = reader.boolean(), looped = reader.boolean();
    final attenuation = reader.float64();
    final voice = _Voice(slot);
    voice.lfo.loadState(reader);
    voice.feg.loadState(reader);
    final decoded = reader.boolean() ? reader.ints() : null;
    final stream =
        reader.boolean() ? DcAicaAdpcmStream.fromState(memory, reader) : null;
    if (index != slot ||
        registers.length != 18 ||
        registers.any((value) => value < 0 || value > 0xffff) ||
        (values.length != 6 && values.length != 7) ||
        extra < 0 ||
        extra > 3 ||
        (values.length == 7 && extra == 0) ||
        (history != null &&
            (history.length != 2 || history.any((value) => !value.isFinite))) ||
        !attenuation.isFinite ||
        attenuation < 0 ||
        attenuation > 1023) {
      throw const StateMismatch('AICA voice state');
    }
    if (values[0] < 0 ||
        values[1] < 0 ||
        values[1] > 3 ||
        values[2] < 0 ||
        values[3] < -1 ||
        values[4] < -32768 ||
        values[4] > 32767 ||
        values[5] < 127 ||
        values[5] > 24576 ||
        (decoded != null &&
            (decoded.isEmpty ||
                decoded.length > 65536 ||
                values[3] >= decoded.length ||
                decoded.any((value) => value < -32768 || value > 32767)))) {
      throw const StateMismatch('AICA voice decoder state');
    }
    final format = (registers[0] >> 7) & 3;
    final noiseSelected = registers[0] & 0x400 != 0;
    if ((noise != null &&
            (!noiseSelected || decoded != null || stream != null)) ||
        (active && noiseSelected && noise == null)) {
      throw const StateMismatch('AICA noise source binding');
    }
    if (active &&
        !noiseSelected &&
        ((format == 2 &&
                (decoded == null || decoded.length != registers[3] + 1)) ||
            (format == 3 &&
                (stream == null ||
                    stream.start !=
                        ((registers[0] & 127) << 16 | registers[1]) ||
                    stream.loopStart != registers[2] ||
                    stream.end != registers[3])))) {
      throw const StateMismatch('AICA voice source binding');
    }
    voice.regs.setAll(0, registers);
    voice.phase = values[0];
    voice.state = values[1];
    voice.streamBase = values[2];
    voice.decodedIndex = values[3];
    voice.predictor = values[4];
    voice.quantization = values[5];
    voice.active = active;
    voice.looped = looped;
    voice.attenuation = attenuation;
    if (history != null) {
      voice.filter.z1 = history[0];
      voice.filter.z2 = history[1];
    }
    voice.decoded = decoded == null ? null : Int16List.fromList(decoded);
    voice.stream = stream;
    voice.noise = noise;
    return voice;
  }

  void start(Uint8List memory) {
    filter.reset();
    feg.start(regs[11]);
    active = true;
    looped = false;
    phase = 0;
    state = 0;
    attenuation = 1023;
    streamBase = 0;
    noise = noiseSelected ? DcAicaNoise(slot) : null;
    stream = !noiseSelected && (regs[0] >> 7) & 3 == 3
        ? DcAicaAdpcmStream(memory,
            start: startAddress, loopStart: regs[2], end: regs[3])
        : null;
    decodedIndex = -1;
    predictor = 0;
    quantization = 127;
    decoded = !noiseSelected && (regs[0] >> 7) & 3 == 2
        ? Int16List(regs[3] + 1)
        : null;
  }
}
