// Dart imports:
import 'dart:developer';
import 'dart:math' as math;
import 'dart:typed_data';

// Project imports:
import '../../../util.dart';
import '../pce.dart';
import 'bus.dart';

class Wave {
  int freq = 0;
  int counter = 0;
  int tableIndex = 0;
  int tableWriteIndex = 0;
  int volume = 0;
  int volumeL = 0;
  int volumeR = 0;
  bool enabled = false;
  int lfoFreq = 0;

  bool dda = false;
  int ddaValue = 0;
  int prevDdaValue = 0;

  bool noise = false;
  int noiseFreq = 0;
  final random = math.Random();

  int currentL = 0;
  int currentR = 0;

  static final table = List.filled(32, 0, growable: false);

  void reset() {
    counter = 0;
    tableIndex = 0;
    tableWriteIndex = 0;
    volume = 0;
    volumeL = 0;
    volumeR = 0;
    enabled = false;
    lfoFreq = 0;
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
    for (int i = 0; i < out.length; i += 2) {
      if (prevDdaValue != ddaValue) {
        prevDdaValue = ddaValue;
        final out = (ddaValue - 16) * (volume + 1);
        currentL = out * (volumeL + 1) ~/ (32 * 16);
        currentR = out * (volumeR + 1) ~/ (32 * 16);
      }

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

          // volume: 5bit volumeLR: 4bit = 9bit
          final out = (random.nextDouble() - 0.5) * (volume + 1);
          currentL = out * (volumeL + 1) ~/ 32;
          currentR = out * (volumeR + 1) ~/ 32;
        }
      }

      out[i + 0] += currentL;
      out[i + 1] += currentR;
    }

    return out;
  }

  List<int> synthWave(List<int> out) {
    for (int i = 0; i < out.length; i += 2) {
      out[i + 0] += currentL;
      out[i + 1] += currentR;

      for (int i = 0; i < Psg.divider; i++) {
        counter = (counter - 1) & 0xfff;

        if (counter == 1) {
          counter = freq;
          tableIndex = (tableIndex + 1) & 0x1f;

          // volume: 5bit volumeLR: 4bit = 9bit
          final out =
              ((dda ? ddaValue : table[tableIndex]) - 16) * (volume + 1);
          currentL = out * (volumeL + 1) ~/ (32 * 16);
          currentR = out * (volumeR + 1) ~/ (32 * 16);
        }
      }
    }

    return out;
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
  static const audioSamplingRate = Pce.systemClock ~/ 6 ~/ divider;

  final waves = List<Wave>.generate(6, (_) => Wave());

  int ch = 0;
  int ampL = 0;
  int ampR = 0;

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
          waves[ch].ddaValue = val;
        } else {
          waves[ch].pushWave(val & 0x1f);
        }
        return;

      case 0x07: // noise ch4 or 5 only
        if (ch == 4 || ch == 5) {
          waves[ch].noise = bit7(val);
          waves[ch].noiseFreq = val & 0x1f;
        }
        return;

      case 0x08:
        waves[ch].lfoFreq = val;
        return;

      case 0x09: // LFO control ch0 or 1 only
        return;

      default:
        log("Unsupported apu write at 0x${hex16(reg)}");
        return;
    }
  }

  int read(int reg) {
    return 0xff;
  }

  /// Generates the output with the duration against given elapsed clocks
  Float32List exec(int elapsedClocks) {
    final cycles =
        elapsedClocks ~/ 3 ~/ 2 ~/ divider; // 3.579545MHz / 8(sample)

    final buffer = Float32List(cycles * 2); // -1.0 .. 1.0 2 channel interleaved

    final out = List<int>.filled(buffer.length, 0);
    for (int i = 0; i < waves.length; i++) {
      waves[i].synth(out); // -16 .. 15, 2 channel interleaved 5bit PCM
    }

    for (int i = 0; i < buffer.length; i += 2) {
      buffer[i + 0] = out[i + 0] * (ampL + 1) / 16 / waves.length / 32;
      buffer[i + 1] = out[i + 1] * (ampR + 1) / 16 / waves.length / 32;
    }

    return buffer;
  }
}
