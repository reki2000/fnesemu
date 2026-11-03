import 'dart:math' as math;
import 'dart:typed_data';

import '../../../util/debug.dart';
import '../../../util/int.dart';
import '../../../util/state.dart';
import '../constants.dart' as hardware;
import 'bus.dart';

final _log = DebugLog('pce.psg');

class Wave {
  bool enabled = false;

  int freq = 0;
  int freqOffset = 0;

  final table = List.filled(32, 0, growable: false);
  int counter = 0;
  int tableIndex = 0;
  int tableWriteIndex = 0;

  int volume = 0;
  int volumeL = 0;
  int volumeR = 0;

  bool dda = false;
  int ddaValue = 0;

  bool noise = false;
  int noiseFreq = 0;
  int noiseIndex = 0;
  int noiseCounter = 0;
  int noiseValue = 0;
  math.Random random = math.Random(0); // fixed seed: deterministic noise

  // The number of values drawn from [random]; a state restores the noise sequence by replaying this many draws on a fresh generator with the same seed.
  int noiseDraws = 0;

  int currentL = 0;
  int currentR = 0;

  void reset() {
    enabled = false;

    freq = 0;
    freqOffset = 0;

    table.fillRange(0, table.length, 0);
    counter = 0;
    tableIndex = 0;
    tableWriteIndex = 0;

    volume = 0;
    volumeL = 0;
    volumeR = 0;

    dda = false;
    ddaValue = 0;

    noise = false;
    noiseFreq = 0;
    noiseIndex = 0;
    noiseCounter = 0;
    noiseValue = 0;

    currentL = 0;
    currentR = 0;
  }

  /// Saves the channel registers, the wave table and the noise generator position.
  void saveState(StateWriter w) {
    w.section('pce-psg-wave');
    w.ints([
      freq, freqOffset, counter, tableIndex, tableWriteIndex, volume, //
      volumeL, volumeR, ddaValue, noiseFreq, noiseIndex, noiseCounter, //
      noiseValue, noiseDraws, currentL, currentR
    ]);
    w.ints(table);
    w.boolean(enabled);
    w.boolean(dda);
    w.boolean(noise);
  }

  /// Restores the state written by [saveState], replaying the noise draws so the generator continues the saved sequence.
  void loadState(StateReader s) {
    s.section('pce-psg-wave');
    final v = s.ints();
    if (v.length != 16) throw const StateMismatch('psg wave state layout');
    freq = v[0];
    freqOffset = v[1];
    counter = v[2];
    tableIndex = v[3];
    tableWriteIndex = v[4];
    volume = v[5];
    volumeL = v[6];
    volumeR = v[7];
    ddaValue = v[8];
    noiseFreq = v[9];
    noiseIndex = v[10];
    noiseCounter = v[11];
    noiseValue = v[12];
    noiseDraws = v[13];
    currentL = v[14];
    currentR = v[15];
    s.intsInto(table);
    enabled = s.boolean();
    dda = s.boolean();
    noise = s.boolean();
    random = math.Random(0);
    for (var i = 0; i < noiseDraws; i++) {
      random.nextDouble();
    }
  }

  void pushWave(int val) {
    table[tableWriteIndex] = val;
    tableWriteIndex = (tableWriteIndex + 1).mask5;
  }

  // generate 2 channel interleaved 5bit PCM
  List<int> synth(List<int> out) {
    return dda
        ? synthDda(out)
        : noise
            ? synthNoise(out)
            : synthWave(out);
  }

  List<int> synthDda(List<int> out) {
    final vol = (ddaValue - 16) * (volume + 1);
    currentL = vol * (volumeL + 1) ~/ (32 * 16);
    currentR = vol * (volumeR + 1) ~/ (32 * 16);

    for (int i = 0; i < out.length; i += 2) {
      out[i + 0] += currentL;
      out[i + 1] += currentR;
    }

    return out;
  }

  List<int> synthNoise(List<int> out) {
    // The noise clock divides the PSG clock by 64 times the inverted R7
    // value. A zero divisor is undocumented; use the shortest period.
    final period = 64 * (noiseFreq > 0 ? noiseFreq : 1);
    for (int i = 0; i < out.length; i += 2) {
      noiseCounter -= Psg.divider;
      while (noiseCounter <= 0) {
        noiseCounter += period;
        noiseIndex = (noiseIndex + 1).mask6;
        noiseDraws++;
        noiseValue = random.nextDouble() > 0.5 ? 15 : -16;
      }
      final level = volume == 0 ? 0 : noiseValue * (volume + 1);
      currentL = level * (volumeL + 1) ~/ (32 * 16);
      currentR = level * (volumeR + 1) ~/ (32 * 16);
      out[i + 0] += currentL;
      out[i + 1] += currentR;
    }

    return out;
  }

  // The 12-bit wave counter reloads when it reaches 1. Skip the steps
  // before that reload instead of stepping Psg.divider times per sample.
  List<int> synthWave(List<int> out) {
    for (int i = 0; i < out.length; i += 2) {
      int steps = Psg.divider;
      while (true) {
        final toReload = (counter - 2).mask12 + 1;
        if (toReload > steps) {
          counter = (counter - steps).mask12;
          break;
        }
        steps -= toReload;

        counter = _clip(freq + freqOffset, 0, 0xfff);
        tableIndex = (tableIndex + 1).mask5;

        // volume: 5bit volumeLR: 4bit = 9bit
        final out = ((dda ? ddaValue : table[tableIndex]) - 16) * (volume + 1);
        currentL = out * (volumeL + 1) ~/ (32 * 16);
        currentR = out * (volumeR + 1) ~/ (32 * 16);
      }

      out[i + 0] += currentL;
      out[i + 1] += currentR;
    }

    return out;
  }

  int _clip(int val, int min, int max) {
    return val < min
        ? min
        : val > max
            ? max
            : val;
  }
}

/// Emulates PSG
class Psg {
  late final Bus _bus;

  Psg(bus) {
    _bus = bus;
    _bus.psg = this;
  }

  void reset() {
    cycle = 0;
    ampL = 0;
    ampR = 0;
    for (final wave in waves) {
      wave.reset();
    }
  }

  int cycle = 0;

  static const divider = 8; // divider for 3.579545MHz
  static const audioSamplingRate = hardware.systemClockHz ~/ 6 ~/ divider;

  final waves = List<Wave>.generate(6, (_) => Wave());

  int ch = 0;
  int ampL = 0;
  int ampR = 0;

  int lfoFreq = 0;
  bool lfoEnabled = false;
  int lfoControl = 0;
  int lfoCounter = 0;

  /// Saves the channel selection, the main amplitudes, the LFO state and every wave channel.
  void saveState(StateWriter w) {
    w.section('pce-psg');
    w.ints([cycle, ch, ampL, ampR, lfoFreq, lfoControl, lfoCounter]);
    w.boolean(lfoEnabled);
    for (final wave in waves) {
      wave.saveState(w);
    }
  }

  /// Restores the state written by [saveState].
  void loadState(StateReader s) {
    s.section('pce-psg');
    final v = s.ints();
    if (v.length != 7) throw const StateMismatch('psg state layout');
    cycle = v[0];
    ch = v[1];
    ampL = v[2];
    ampR = v[3];
    lfoFreq = v[4];
    lfoControl = v[5];
    lfoCounter = v[6];
    lfoEnabled = s.boolean();
    for (final wave in waves) {
      wave.loadState(s);
    }
  }

  void write(int reg, int val) {
    switch (reg) {
      // pulse wave 0
      case 0x00:
        if (val.mask3 < 6) {
          ch = val.mask3;
        }
        return;

      case 0x01:
        ampR = val.mask4;
        ampL = val.shr4;
        return;

      case 0x02:
        waves[ch].freq = waves[ch].freq.setL8(val);
        return;

      case 0x03:
        waves[ch].freq = waves[ch].freq.setH8(val.mask4);
        return;

      case 0x04:
        waves[ch].volume = val.mask5;
        waves[ch].enabled = val.bit7;
        waves[ch].dda = val.bit6;
        // DDA
        return;

      case 0x05:
        waves[ch].volumeR = val.mask4;
        waves[ch].volumeL = val.shr4;
        return;

      case 0x06: // waveform
        if (waves[ch].dda) {
          if (waves[ch].enabled) {
            waves[ch].ddaValue = val;
          } else {
            waves[ch].tableWriteIndex = 0;
          }
        } else {
          if (!waves[ch].enabled) {
            waves[ch].pushWave(val);
          }
        }
        return;

      case 0x07: // noise ch4 or 5 only
        if (ch == 4 || ch == 5) {
          waves[ch].noise = val.bit7;
          waves[ch].noiseFreq = val.mask5 ^ 0x1f;
        }
        return;

      case 0x08:
        lfoFreq = val;
        return;

      case 0x09: // LFO control ch0 or 1 only
        lfoEnabled = val.bit7;
        if (!lfoEnabled) {
          waves[1].tableIndex = 0;
        }
        lfoControl = val.mask2;
        return;

      default:
        _log.warnc(() => "Unsupported apu write at 0x${reg.x4}");
        return;
    }
  }

  int read(int reg) {
    return 0xff;
  }

  // generate table which has output volume values, 15 to 0 with each step -1.5dB
  final volumeTable = List.generate(16, (i) => i == 0 ? 0 : (0.3 / (16 - i)));

  var buffer = Float32List(0); // -1.0 .. 1.0 2 channel interleaved

  var _out = Int32List(0); // mix of the channels, reused

  /// Generates the output with the duration against given elapsed clocks
  Float32List exec(int elapsedClocks) {
    cycle += elapsedClocks;
    final cycles = cycle ~/ (6 * divider);
    cycle %= 6 * divider;

    if (_out.length != cycles * 2) {
      _out = Int32List(cycles * 2);
    } else {
      _out.fillRange(0, _out.length, 0);
    }
    final out = _out;

    for (int i = waves.length - 1; i >= 0; i--) {
      if (i == 1 && lfoEnabled) {
        _applyLfo(out.length);
      } else if (waves[i].enabled) {
        waves[i].synth(out); // -16 .. 15, 2 channel interleaved 5bit PCM
      }
    }

    if (buffer.length != cycles * 2) {
      buffer = Float32List(cycles * 2);
    }

    final ampLrate = volumeTable[ampL] / 6 / 16;
    final ampRrate = volumeTable[ampR] / 6 / 16;
    for (int i = 0; i < buffer.length; i += 2) {
      buffer[i + 0] = out[i + 0] * ampLrate;
      buffer[i + 1] = out[i + 1] * ampRrate;
    }

    return buffer;
  }

  _applyLfo(int length) {
    for (int j = 0; j < length; j++) {
      lfoCounter = (lfoCounter - 1) & 0x3ffff;
      if (lfoCounter == 0) {
        lfoCounter = 0;
        waves[1].tableIndex = (waves[1].tableIndex + 1).mask5;
      }
    }

    // apply lfo offset to wave 0
    final lfoVal = waves[1].table[waves[1].tableIndex];
    waves[0].freqOffset = switch (lfoControl) {
      1 => lfoVal - 16,
      2 => lfoVal.shl4 - 256,
      3 => lfoVal.shl8 - 4096,
      _ => 0
    };
  }
}
