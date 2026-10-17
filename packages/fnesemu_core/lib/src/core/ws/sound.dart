import 'dart:typed_data';

import '../../util/int.dart';

/// the four wavetable channels of the WonderSwan, with the voice mode of the
/// channel 2, the sweep of the channel 3 and the noise of the channel 4
class Sound {
  /// the I/O ports 0x00-0xff, of which the sound uses 0x80-0x94
  final Uint8List io;

  /// the internal RAM holding the wave tables
  final Uint8List ram;

  Sound(this.io, this.ram);

  static const clockHz = 3072000;
  static const _clocksPerSample = 64;
  static const sampleRate = clockHz ~/ _clocksPerSample; // 48kHz

  final _counter = List<int>.filled(4, 0);
  final _position = List<int>.filled(4, 0);
  int _sweepCounter = 0;
  int _lfsr = 0;
  int _noiseOut = 0;

  int _clocks = 0;

  final buffer = Float32List(2 * 4096);
  int samples = 0;

  void reset() {
    _counter.fillRange(0, 4, 0);
    _position.fillRange(0, 4, 0);
    _sweepCounter = 0;
    _lfsr = 0;
    _noiseOut = 0;
    _clocks = 0;
    samples = 0;
  }

  /// handles writes to the sound ports which have side effects
  void write(int port, int value) {
    if (port == 0x8e && value.bit3) {
      _lfsr = 0;
      io[0x8e] = value & ~0x08;
    }
  }

  int get lfsr => _lfsr;

  int _freq(int ch) => io[0x80 + ch * 2] | io[0x81 + ch * 2].mask3.shl8;

  static const _taps = [14, 10, 13, 4, 8, 6, 9, 11];

  /// advances the channels by [clocks] CPU clocks and renders the samples
  void run(int clocks) {
    _clocks += clocks;
    while (_clocks >= _clocksPerSample) {
      _clocks -= _clocksPerSample;
      _step();
    }
  }

  void _step() {
    final ctrl = io[0x90];

    // the channel 3 sweep at 375Hz / (time + 1)
    if (ctrl.bit6) {
      _sweepCounter -= _clocksPerSample;
      if (_sweepCounter <= 0) {
        _sweepCounter += (io[0x8d] + 1) * 8192;
        final freq = (_freq(2) + io[0x8c].rel8).mask11;
        io[0x84] = freq.mask8;
        io[0x85] = freq.shr8;
      }
    }

    var left = 0, right = 0;
    for (var ch = 0; ch < 4; ch++) {
      if (!ctrl.bit(ch)) continue;
      final period = 2048 - _freq(ch);
      _counter[ch] -= _clocksPerSample;
      while (_counter[ch] <= 0) {
        _counter[ch] += period;
        if (ch == 3 && ctrl.bit7) {
          final tap = _taps[io[0x8e].mask3];
          final bit = (1 ^ (_lfsr >> 7) ^ (_lfsr >> tap)) & 1;
          _lfsr = (_lfsr << 1 | bit).mask15;
          _noiseOut = _lfsr.bit0 ? 15 : 0;
        } else {
          _position[ch] = (_position[ch] + 1).mask5;
        }
      }

      if (ch == 1 && ctrl.bit5) {
        // voice: the volume register holds an unsigned 8-bit sample
        final v = io[0x89];
        final voice = io[0x94];
        left += voice.bit3 ? v : (voice.bit2 ? v >> 1 : 0);
        right += voice.bit1 ? v : (voice.bit0 ? v >> 1 : 0);
        continue;
      }

      final int sample;
      if (ch == 3 && ctrl.bit7) {
        sample = io[0x8e].bit4 ? _noiseOut : 0;
      } else {
        final addr = io[0x8f].shl6 + ch * 16 + _position[ch].shr1;
        final b = ram[addr];
        sample = _position[ch].bit0 ? b.shr4 : b.mask4;
      }
      final vol = io[0x88 + ch];
      left += sample * vol.shr4;
      right += sample * vol.mask4;
    }

    if (samples * 2 < buffer.length) {
      // 4 channels of 4-bit samples with 4-bit volumes: 0-900
      buffer[samples * 2] = left / 1024;
      buffer[samples * 2 + 1] = right / 1024;
      samples++;
    }
  }

  /// writes a byte from the sound DMA to the voice channel
  void dmaWrite(int value) {
    io[0x89] = value;
  }

  String dump() => "snd: ctl:${io[0x90].x2} out:${io[0x91].x2} "
      "f:${List.generate(4, (ch) => _freq(ch).x4).join(" ")} "
      "v:${List.generate(4, (ch) => io[0x88 + ch].x2).join(" ")}";
}
