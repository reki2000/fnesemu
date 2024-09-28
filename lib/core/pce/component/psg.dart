// Dart imports:
import 'dart:developer';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../../util.dart';
import '../pce.dart';
import 'bus.dart';

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
  final random = math.Random();

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

    currentL = 0;
    currentR = 0;
  }

  void pushWave(int val) {
    table[tableWriteIndex] = val;
    tableWriteIndex = (tableWriteIndex + 1) & 0x1f;
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
    for (int i = 0; i < out.length; i += 2) {
      for (int i = 0; i < Psg.divider; i++) {
        counter = (counter - 1) & 0xfff;

        if (counter == 1) {
          counter = noiseFreq;
          noiseIndex = (noiseIndex + 1) & 0x3f;

          if (noiseIndex == 0 || noiseIndex == 0x10) {
            // volume: 5bit volumeLR: 4bit = 9bit
            final out = (random.nextDouble() > 0.5) ? 31 : 0;
            currentL = out * (volumeL + 1) ~/ 32;
            currentR = out * (volumeR + 1) ~/ 32;
          }
        }
      }

      out[i + 0] += currentL;
      out[i + 1] += currentR;
    }

    return out;
  }

  List<int> synthWave(List<int> out) {
    for (int i = 0; i < out.length; i += 2) {
      for (int i = 0; i < Psg.divider; i++) {
        counter = (counter - 1) & 0xfff;

        if (counter == 1) {
          counter = _clip(freq + freqOffset, 0, 0xfff);
          tableIndex = (tableIndex + 1) & 0x1f;

          // volume: 5bit volumeLR: 4bit = 9bit
          final out =
              ((dda ? ddaValue : table[tableIndex]) - 16) * (volume + 1);
          currentL = out * (volumeL + 1) ~/ (32 * 16);
          currentR = out * (volumeR + 1) ~/ (32 * 16);
        }
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
  static const audioSamplingRate = Pce.systemClockHz_ ~/ 6 ~/ divider;

  final waves = List<Wave>.generate(6, (_) => Wave());

  int ch = 0;
  int ampL = 0;
  int ampR = 0;

  int lfoFreq = 0;
  bool lfoEnabled = false;
  int lfoControl = 0;
  int lfoCounter = 0;

  void write(int reg, int val) {
    switch (reg) {
      // pulse wave 0
      case 0x00:
        if ((val & 0x07) < 6) {
          ch = val & 0x07;
        }
        return;

      case 0x01:
        ampR = val & 0x0f;
        ampL = val >> 4;
        return;

      case 0x02:
        waves[ch].freq = waves[ch].freq.withLowByte(val);
        return;

      case 0x03:
        waves[ch].freq = waves[ch].freq.withHighByte(val & 0x0f);
        return;

      case 0x04:
        waves[ch].volume = val & 0x1f;
        waves[ch].enabled = bit7(val);
        waves[ch].dda = bit6(val);
        // DDA
        return;

      case 0x05:
        waves[ch].volumeR = val & 0x0f;
        waves[ch].volumeL = val >> 4;
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
          waves[ch].noise = bit7(val);
          waves[ch].noiseFreq = (val & 0x1f) ^ 0x1f;
        }
        return;

      case 0x08:
        lfoFreq = val;
        return;

      case 0x09: // LFO control ch0 or 1 only
        lfoEnabled = bit7(val);
        if (!lfoEnabled) {
          waves[1].tableIndex = 0;
        }
        lfoControl = val & 0x03;
        return;

      default:
        log("Unsupported apu write at 0x${hex16(reg)}");
        return;
    }
  }

  int read(int reg) {
    return 0xff;
  }

  // generate table which has output volume values, 15 to 0 with each step -1.5dB
  final volumeTable =
      Float32List.fromList(List.generate(16, (i) => 1 / (16 - i)));

  /// Generates the output with the duration against given elapsed clocks
  Float32List exec(int elapsedClocks) {
    final cycles = elapsedClocks ~/ 6 ~/ divider; // 3.579545MHz / 8(sample)

    final buffer = Float32List(cycles * 2); // -1.0 .. 1.0 2 channel interleaved

    final out = List<int>.filled(buffer.length, 0);
    int addedChannels = 0;

    for (int i = waves.length - 1; i >= 0; i--) {
      if (i == 1 && lfoEnabled) {
        _applyLfo(out.length);
      } else if (waves[i].enabled) {
        addedChannels++;
        waves[i].synth(out); // -16 .. 15, 2 channel interleaved 5bit PCM
      }
    }

    if (addedChannels == 0) {
      return buffer;
    }

    final ampLrate = volumeTable[ampL] / addedChannels / 16;
    final ampRrate = volumeTable[ampR] / addedChannels / 16;
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
        waves[1].tableIndex = (waves[1].tableIndex + 1) & 0x1f;
      }
    }

    // apply lfo offset to wave 0
    final lfoVal = waves[1].table[waves[1].tableIndex];
    waves[0].freqOffset = switch (lfoControl) {
      1 => lfoVal - 16,
      2 => (lfoVal << 4) - 256,
      3 => (lfoVal << 8) - 4096,
      _ => 0
    };
  }
}
