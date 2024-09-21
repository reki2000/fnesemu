// Dart imports:
import 'dart:developer';
import 'dart:typed_data';

// Project imports:
import '../../util.dart';
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
  Int8List synth(int cycles) {
    final buf = Int8List(cycles * 2);

    for (int i = 0; i < buf.length; i += 2) {
      buf[i] = currentL;
      buf[i + 1] = currentR;

      counter = (counter - 1) & 0xfff;

      if (counter == 1) {
        counter = freq;
        tableIndex = (tableIndex + 1) & 0x1f;

        // volume: 5bit volumeLR: 4bit = 9bit
        final out = table[tableIndex] * (volume + 1);
        currentL = out * (volumeL + 1) >> 9;
        currentR = out * (volumeR + 1) >> 9;
      }
    }

    return buf;
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
    buffer.fillRange(0, buffer.length, 0.0);
    for (final wave in waves) {
      wave.reset();
    }
  }

  int cycle = 0;

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
        // DDA
        return;

      case 0x05:
        waves[ch].volumeR = val & 0x0f;
        waves[ch].volumeL = val >> 4;
        return;

      case 0x06: // waveform
        waves[ch].pushWave(val & 0x1f);
        return;

      case 0x07: // noise ch4 or 5 only
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

  /// sound output buffer: -1.0 to 1.0 for 1 screen frame @
  final buffer = Float32List(21477270 / 59.97 ~/ 6 * 2);
  var bufferIndex = 0;

  /// Generates APU 1Frame output and set it to the apu output buffer
  void exec(elapsedClocks) {
    final cycles = elapsedClocks ~/ 3 ~/ 2; // 3.579545MHz

    var out = List.filled(6, Int8List(0));
    for (int i = 0; i < waves.length; i++) {
      out[i] = waves[i].synth(cycles); // 0 - 32, 2 channel interleave
    }

    for (int i = 0; i < cycles * 2; i += 2) {
      int volL = 0;
      int volR = 0;
      for (int j = 0; j < waves.length; j++) {
        volL += out[j][i];
        volR += out[j][i + 1];
      }

      buffer[bufferIndex++] =
          (volL * (ampL + 1) / 16) / waves.length / 32 - 1.0;
      buffer[bufferIndex++] =
          (volR * (ampR + 1) / 16) / waves.length / 32 - 1.0;
      if (bufferIndex >= buffer.length) {
        bufferIndex = 0;
      }
    }
  }
}
