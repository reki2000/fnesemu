import 'dart:typed_data';

import '../../../util/int.dart';

// MMC5 expansion audio: 2 pulse channels (no sweep, length counter and
// envelope are both clocked at 240Hz) and an 8bit PCM channel.
// https://www.nesdev.org/wiki/MMC5_audio
class _Pulse {
  static const _lengthTable = [
    10, 254, 20, 2, 40, 4, 80, 6, 160, 8, 60, 10, 14, 12, 26, 14, //
    12, 16, 24, 18, 48, 20, 96, 22, 192, 24, 72, 26, 16, 28, 32, 30
  ];

  static const _waveTable = [
    [0, 1, 0, 0, 0, 0, 0, 0],
    [0, 1, 1, 0, 0, 0, 0, 0],
    [0, 1, 1, 1, 1, 0, 0, 0],
    [1, 0, 0, 1, 1, 1, 1, 1],
  ];

  bool enabled = false;
  int dutyType = 0;
  bool halt = false; // also the envelope loop flag
  bool constantVolume = false;
  int volumeOrPeriod = 0;
  int freq = 0;
  int lengthCounter = 0;

  int _timer = 0;
  int _index = 0;

  // envelope
  bool _envStart = false;
  int _decay = 0;
  int _divider = 0;

  void writeControl(int val) {
    dutyType = val.shr6;
    halt = val.bit5;
    constantVolume = val.bit4;
    volumeOrPeriod = val.mask4;
  }

  void writeFreqLow(int val) {
    freq = freq.setL8(val);
  }

  void writeFreqHigh(int val) {
    freq = freq.setH8(val.mask3);
    if (enabled) {
      lengthCounter = _lengthTable[val.shr3.mask5];
    }
    _index = 0;
    _envStart = true;
  }

  void setEnabled(bool on) {
    enabled = on;
    if (!on) {
      lengthCounter = 0;
    }
  }

  int get volume => constantVolume ? volumeOrPeriod : _decay;

  // 240Hz clock for both the envelope and the length counter
  void clock240() {
    if (_envStart) {
      _envStart = false;
      _decay = 15;
      _divider = volumeOrPeriod;
    } else if (_divider > 0) {
      _divider--;
    } else {
      _divider = volumeOrPeriod;
      if (_decay > 0) {
        _decay--;
      } else if (halt) {
        _decay = 15;
      }
    }

    if (lengthCounter > 0 && !halt) {
      lengthCounter--;
    }
  }

  // 1 sample = 1 apu cycle (= 2 cpu cycles)
  int output() {
    if (!enabled || lengthCounter == 0) {
      return 0;
    }
    if (_timer <= 0) {
      _timer = freq;
      _index = (_index + 1).mask3;
    } else {
      _timer--;
    }
    return _waveTable[dutyType][_index] == 1 ? volume : 0;
  }
}

class Mmc5Apu {
  static const _apuRate = 1789773 ~/ 2;

  final pulse0 = _Pulse();
  final pulse1 = _Pulse();

  int pcm = 0;
  bool pcmReadMode = false;
  bool pcmIrqEnabled = false;

  int _tickAcc = 0;

  // same non linear mixing as the 2A03 pulse channels
  static final _pulseOutTable = List<double>.generate(
      31, (n) => n == 0 ? 0 : 95.52 / (8128.0 / n + 100));
  static final _pcmOutTable = List<double>.generate(
      128, (n) => n == 0 ? 0 : 163.67 / (24329.0 / n + 100));

  void write(int addr, int data) {
    switch (addr) {
      case 0x5000:
        pulse0.writeControl(data);
      case 0x5002:
        pulse0.writeFreqLow(data);
      case 0x5003:
        pulse0.writeFreqHigh(data);
      case 0x5004:
        pulse1.writeControl(data);
      case 0x5006:
        pulse1.writeFreqLow(data);
      case 0x5007:
        pulse1.writeFreqHigh(data);
      case 0x5010:
        pcmReadMode = data.bit0;
        pcmIrqEnabled = data.bit7;
      case 0x5011:
        // writes to the pcm are ignored in read mode and when the value is 0
        if (!pcmReadMode && data != 0) {
          pcm = data;
        }
      case 0x5015:
        pulse0.setEnabled(data.bit0);
        pulse1.setEnabled(data.bit1);
    }
  }

  int readStatus() =>
      (pulse0.lengthCounter > 0 ? 1 : 0) | (pulse1.lengthCounter > 0 ? 2 : 0);

  var buffer = Float32List(0);

  Float32List exec(int cpuCycles) {
    final cycles = cpuCycles ~/ 2;

    if (buffer.length != cycles) {
      buffer = Float32List(cycles);
    }

    final pcmOut = _pcmOutTable[pcm.shr1];
    for (int i = 0; i < cycles; i++) {
      _tickAcc += 240;
      if (_tickAcc >= _apuRate) {
        _tickAcc -= _apuRate;
        pulse0.clock240();
        pulse1.clock240();
      }
      buffer[i] = _pulseOutTable[pulse0.output() + pulse1.output()] + pcmOut;
    }

    return buffer;
  }

  String dump() =>
      "p0:${pulse0.dutyType} ${pulse0.volume} ${pulse0.freq} len:${pulse0.lengthCounter} "
      "p1:${pulse1.dutyType} ${pulse1.volume} ${pulse1.freq} len:${pulse1.lengthCounter} "
      "pcm:$pcm";
}
