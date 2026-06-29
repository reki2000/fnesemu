import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';

import 'bus.dart';

/// GBA audio: 4 GB-compatible PSG channels plus the two 8-bit Direct Sound
/// FIFO channels, mixed to a stereo [Float32List] at [sampleHz].
///
/// PSG channels are synthesised with phase accumulators at the output sample
/// rate (not cycle-exact, but stable in pitch). Direct Sound levels are latched
/// from their FIFO on the selected timer's overflow and refilled by DMA.
class Apu {
  final Bus bus;
  Apu(this.bus);

  int sampleHz = 32768;
  int elapsedSamples = 0;

  final _sq1 = _Square(hasSweep: true);
  final _sq2 = _Square();
  final _wave = _Wave();
  final _noise = _Noise();

  // Direct Sound FIFOs (bytes) and last latched output level (signed).
  final _fifoA = _Fifo();
  final _fifoB = _Fifo();
  int _dsaLevel = 0;
  int _dsbLevel = 0;

  // cached control registers
  int _cntL = 0; // SOUNDCNT_L
  int _cntH = 0; // SOUNDCNT_H
  int _cntX = 0; // SOUNDCNT_X

  bool get _masterEnable => _cntX.bit7;

  void reset() {
    elapsedSamples = 0;
    _sq1.reset();
    _sq2.reset();
    _wave.reset();
    _noise.reset();
    _fifoA.clear();
    _fifoB.clear();
    _dsaLevel = 0;
    _dsbLevel = 0;
    _cntL = 0;
    _cntH = 0;
    _cntX = 0;
  }

  // --- register access (reg = 0x060..0x0a7) ---------------------------------

  void write16(int reg, int data) {
    data &= 0xffff;
    switch (reg) {
      case 0x60:
        _sq1.writeSweep(data);
        return;
      case 0x62:
        _sq1.writeDutyEnv(data, sampleHz);
        return;
      case 0x64:
        _sq1.writeFreqCtrl(data, sampleHz);
        return;
      case 0x68:
        _sq2.writeDutyEnv(data, sampleHz);
        return;
      case 0x6c:
        _sq2.writeFreqCtrl(data, sampleHz);
        return;
      case 0x70:
        _wave.writeEnable(data);
        return;
      case 0x72:
        _wave.writeLenVol(data, sampleHz);
        return;
      case 0x74:
        _wave.writeFreqCtrl(data, sampleHz);
        return;
      case 0x78:
        _noise.writeLenEnv(data, sampleHz);
        return;
      case 0x7c:
        _noise.writeFreqCtrl(data, sampleHz);
        return;
      case 0x80:
        _cntL = data;
        return;
      case 0x82:
        _cntH = data;
        if (data.bit11) _fifoA.clear();
        if (data.bit15) _fifoB.clear();
        return;
      case 0x84:
        _cntX = (_cntX & 0xf) | (data & 0xf0);
        return;
      case 0xa0:
      case 0xa2:
        _fifoA.push(data & 0xff);
        _fifoA.push((data >> 8) & 0xff);
        return;
      case 0xa4:
      case 0xa6:
        _fifoB.push(data & 0xff);
        _fifoB.push((data >> 8) & 0xff);
        return;
      default:
        return; // wave RAM (0x90) and others live in bus.io[]
    }
  }

  int read16(int reg) {
    switch (reg) {
      case 0x60:
        return _sq1.sweep;
      case 0x62:
        return _sq1.dutyEnv;
      case 0x64:
        return _sq1.freqCtrl & 0x4000;
      case 0x68:
        return _sq2.dutyEnv;
      case 0x6c:
        return _sq2.freqCtrl & 0x4000;
      case 0x70:
        return _wave.enableReg;
      case 0x72:
        return _wave.lenVol;
      case 0x74:
        return _wave.freqCtrl & 0x4000;
      case 0x78:
        return _noise.lenEnv;
      case 0x7c:
        return _noise.freqCtrl & 0x4000;
      case 0x80:
        return _cntL;
      case 0x82:
        return _cntH;
      case 0x84:
        // bits0-3 channel status, bit7 master enable
        return (_cntX & 0x80) |
            (_sq1.active ? 1 : 0) |
            (_sq2.active ? 2 : 0) |
            (_wave.active ? 4 : 0) |
            (_noise.active ? 8 : 0);
      default:
        return 0;
    }
  }

  /// the selected timer overflowed [count] times; advance Direct Sound.
  void onTimerOverflow(int timerId, int count) {
    final timerA = _cntH.bit10 ? 1 : 0;
    final timerB = _cntH.bit14 ? 1 : 0;
    if (timerId == timerA) {
      for (int i = 0; i < count; i++) {
        if (_fifoA.isNotEmpty) _dsaLevel = _fifoA.pop().toSigned(8);
      }
      if (_fifoA.length <= 16) bus.dma.requestSoundFifo(0x040000a0);
    }
    if (timerId == timerB) {
      for (int i = 0; i < count; i++) {
        if (_fifoB.isNotEmpty) _dsbLevel = _fifoB.pop().toSigned(8);
      }
      if (_fifoB.length <= 16) bus.dma.requestSoundFifo(0x040000a4);
    }
  }

  // --- mixing ---------------------------------------------------------------

  /// render [samples] stereo frames; returns interleaved L,R in [-1, 1].
  Float32List render(int samples) {
    elapsedSamples += samples;
    final out = Float32List(samples * 2);
    if (!_masterEnable) return out;

    _wave.loadRam(bus.io);

    // PSG master volume ratio (SOUNDCNT_H bits0-1): 25/50/100%.
    const psgRatio = [0.25, 0.5, 1.0, 1.0];
    final psgVol = psgRatio[_cntH & 3];

    // PSG per-side enables (SOUNDCNT_L): bits 8-11 right, 12-15 left.
    final psgVolR = ((_cntL >> 4) & 7) / 7;
    final psgVolL = (_cntL & 7) / 7;
    final enRight = (_cntL >> 8) & 0xf;
    final enLeft = (_cntL >> 12) & 0xf;

    // Direct Sound volume (bit2/bit3) and L/R enables.
    final dsaVol = _cntH.bit2 ? 1.0 : 0.5;
    final dsbVol = _cntH.bit3 ? 1.0 : 0.5;
    final dsaR = _cntH.bit8, dsaL = _cntH.bit9;
    final dsbR = _cntH.bit12, dsbL = _cntH.bit13;

    for (int i = 0; i < samples; i++) {
      final c1 = _sq1.render();
      final c2 = _sq2.render();
      final c3 = _wave.render();
      final c4 = _noise.render();

      double psgL = 0, psgR = 0;
      if (enLeft & 1 != 0) psgL += c1;
      if (enLeft & 2 != 0) psgL += c2;
      if (enLeft & 4 != 0) psgL += c3;
      if (enLeft & 8 != 0) psgL += c4;
      if (enRight & 1 != 0) psgR += c1;
      if (enRight & 2 != 0) psgR += c2;
      if (enRight & 4 != 0) psgR += c3;
      if (enRight & 8 != 0) psgR += c4;

      psgL *= psgVol * psgVolL / 4;
      psgR *= psgVol * psgVolR / 4;

      final dsa = (_dsaLevel / 128) * dsaVol;
      final dsb = (_dsbLevel / 128) * dsbVol;

      double l = psgL;
      double r = psgR;
      if (dsaL) l += dsa;
      if (dsaR) r += dsa;
      if (dsbL) l += dsb;
      if (dsbR) r += dsb;

      out[i * 2] = l.clamp(-1.0, 1.0);
      out[i * 2 + 1] = r.clamp(-1.0, 1.0);
    }
    return out;
  }
}

/// simple byte FIFO (max 32 bytes) backed by a ring buffer.
class _Fifo {
  final _buf = Uint8List(32);
  int _head = 0;
  int _len = 0;

  int get length => _len;
  bool get isNotEmpty => _len > 0;

  void push(int b) {
    if (_len >= 32) return;
    _buf[(_head + _len) & 31] = b & 0xff;
    _len++;
  }

  int pop() {
    if (_len == 0) return 0;
    final b = _buf[_head];
    _head = (_head + 1) & 31;
    _len--;
    return b;
  }

  void clear() {
    _head = 0;
    _len = 0;
  }
}

/// shared volume envelope used by the square and noise channels.
class _Envelope {
  int volume = 0;
  bool _increase = false;
  int _periodSamples = 0;
  int _counter = 0;

  void configure(int reg, int sampleHz) {
    // bits 8-10 step time (n/64s), bit11 direction, bits12-15 initial volume
    final step = (reg >> 8) & 7;
    _increase = reg.bit11;
    volume = (reg >> 12) & 0xf;
    _periodSamples = step * sampleHz ~/ 64;
    _counter = _periodSamples;
  }

  void tick() {
    if (_periodSamples == 0) return;
    if (--_counter > 0) return;
    _counter = _periodSamples;
    if (_increase) {
      if (volume < 15) volume++;
    } else {
      if (volume > 0) volume--;
    }
  }
}

/// shared length counter; silences the channel after the configured duration.
class _Length {
  int _counter = 0;
  bool enabled = false;

  void set(int ticks, int sampleHz, int max) {
    _counter = (max - ticks) * sampleHz ~/ 256;
  }

  bool tick() {
    if (!enabled || _counter <= 0) return false;
    _counter--;
    return _counter <= 0; // returns true when it just expired
  }

  bool get expired => enabled && _counter <= 0;
}

class _Square {
  final bool hasSweep;
  _Square({this.hasSweep = false});

  static const _duty = [0.125, 0.25, 0.5, 0.75];

  int sweep = 0;
  int dutyEnv = 0;
  int freqCtrl = 0;

  final _env = _Envelope();
  final _len = _Length();
  double _phase = 0;
  int _freq = 0;
  bool active = false;
  int _sampleHz = 32768;

  // sweep state
  int _sweepCounter = 0;
  int _sweepPeriodSamples = 0;

  void writeSweep(int v) => sweep = v;

  void writeDutyEnv(int v, int sampleHz) {
    dutyEnv = v;
    _env.configure(v, sampleHz);
    _len.set(v & 0x3f, sampleHz, 64);
  }

  void writeFreqCtrl(int v, int sampleHz) {
    freqCtrl = v;
    _sampleHz = sampleHz;
    _freq = freqCtrl & 0x7ff;
    _len.enabled = v.bit14;
    if (v.bit15) _trigger(sampleHz);
  }

  void _trigger(int sampleHz) {
    active = true;
    _env.configure(dutyEnv, sampleHz);
    _len.set(dutyEnv & 0x3f, sampleHz, 64);
    if (hasSweep) {
      final period = (sweep >> 4) & 7;
      _sweepPeriodSamples = period * sampleHz ~/ 128;
      _sweepCounter = _sweepPeriodSamples;
    }
  }

  double render() {
    if (!active) return 0;
    if (_len.tick()) active = false;
    _env.tick();
    _tickSweep();

    if (_freq >= 2048) return 0;
    final hz = 131072 / (2048 - _freq);
    _phase += hz / _sampleHz;
    if (_phase >= 1) _phase -= _phase.floorToDouble();

    final duty = _duty[(dutyEnv >> 6) & 3];
    final level = _phase < duty ? 1.0 : -1.0;
    return level * _env.volume / 15;
  }

  void _tickSweep() {
    if (!hasSweep || _sweepPeriodSamples == 0) return;
    if (--_sweepCounter > 0) return;
    _sweepCounter = _sweepPeriodSamples;
    final shift = sweep & 7;
    if (shift == 0) return;
    final delta = _freq >> shift;
    _freq = sweep.bit3 ? _freq - delta : _freq + delta;
    if (_freq >= 2048) active = false;
    if (_freq < 0) _freq = 0;
  }

  void reset() {
    sweep = dutyEnv = freqCtrl = 0;
    _phase = 0;
    _freq = 0;
    active = false;
  }
}

class _Wave {
  int enableReg = 0;
  int lenVol = 0;
  int freqCtrl = 0;

  final _len = _Length();
  double _phase = 0; // 0..32 over the sample table
  int _freq = 0;
  bool active = false;
  int _sampleHz = 32768;

  // bank pointer into bus wave RAM is read live; here we cache nothing.
  final samples = Uint8List(32); // 4-bit samples expanded by writeRam

  void writeEnable(int v) {
    enableReg = v;
    if (!v.bit7) active = false;
  }

  void writeLenVol(int v, int sampleHz) {
    lenVol = v;
    _len.set(v & 0xff, sampleHz, 256);
  }

  void writeFreqCtrl(int v, int sampleHz) {
    freqCtrl = v;
    _sampleHz = sampleHz;
    _freq = v & 0x7ff;
    _len.enabled = v.bit14;
    if (v.bit15) {
      active = enableReg.bit7;
      _len.set(lenVol & 0xff, sampleHz, 256);
      _phase = 0;
    }
  }

  /// load the 32 4-bit samples from the 16-byte wave RAM in bus.io[0x90].
  void loadRam(List<int> io) {
    for (int i = 0; i < 16; i++) {
      final b = io[0x90 + i];
      samples[i * 2] = b >> 4;
      samples[i * 2 + 1] = b & 0xf;
    }
  }

  double render() {
    if (!active) return 0;
    if (_len.tick()) active = false;
    if (_freq >= 2048) return 0;

    final rate = 2097152 / (2048 - _freq); // table samples per second
    _phase += rate / _sampleHz;
    while (_phase >= 32) {
      _phase -= 32;
    }

    final s = samples[_phase.toInt() & 31];
    // volume: bits13-15 of lenVol (0 mute,1 100%,2 50%,3 25%, bit15 force 75%)
    final volSel = (lenVol >> 13) & 7;
    const volTable = [0.0, 1.0, 0.5, 0.25, 0.75, 0.75, 0.75, 0.75];
    return ((s / 7.5) - 1.0) * volTable[volSel];
  }

  void reset() {
    enableReg = lenVol = freqCtrl = 0;
    _phase = 0;
    _freq = 0;
    active = false;
    samples.fillRange(0, 32, 0);
  }
}

class _Noise {
  int lenEnv = 0;
  int freqCtrl = 0;

  final _env = _Envelope();
  final _len = _Length();
  int _lfsr = 0x7fff;
  bool _width7 = false;
  double _phase = 0;
  double _hz = 0;
  bool active = false;
  int _sampleHz = 32768;

  static const _divisor = [8, 16, 32, 48, 64, 80, 96, 112];

  void writeLenEnv(int v, int sampleHz) {
    lenEnv = v;
    _env.configure(v, sampleHz);
    _len.set(v & 0x3f, sampleHz, 64);
  }

  void writeFreqCtrl(int v, int sampleHz) {
    freqCtrl = v;
    _sampleHz = sampleHz;
    _width7 = v.bit3;
    final shift = (v >> 4) & 0xf;
    final r = v & 7;
    _hz = 524288 / _divisor[r] / (1 << (shift + 1)) * 8;
    _len.enabled = v.bit14;
    if (v.bit15) {
      active = true;
      _env.configure(lenEnv, sampleHz);
      _len.set(lenEnv & 0x3f, sampleHz, 64);
      _lfsr = _width7 ? 0x7f : 0x7fff;
    }
  }

  double render() {
    if (!active) return 0;
    if (_len.tick()) active = false;
    _env.tick();

    _phase += _hz / _sampleHz;
    while (_phase >= 1) {
      _phase -= 1;
      final bit = (_lfsr ^ (_lfsr >> 1)) & 1;
      _lfsr >>= 1;
      _lfsr |= bit << (_width7 ? 6 : 14);
    }

    final level = (_lfsr & 1) == 0 ? 1.0 : -1.0;
    return level * _env.volume / 15;
  }

  void reset() {
    lenEnv = freqCtrl = 0;
    _lfsr = 0x7fff;
    _phase = 0;
    _hz = 0;
    active = false;
  }
}
