import 'dart:typed_data';

import 'dsp.dart';
import 'spc700.dart';

/// drives the SPC700 + DSP from the main 65816's clock. Not cycle-locked to
/// the main CPU (real hardware runs them from independent-but-related
/// oscillators); this cross-multiplies elapsed main-CPU cycles into SPC700
/// cycles so the two stay in proportion without accumulating drift.
class Apu {
  Apu() {
    dsp = Dsp();
    spc = Spc700(dsp);
  }

  late final Dsp dsp;
  late final Spc700 spc;

  static const spcClockHz = 1024000; // ~1.024MHz SPC700/DSP clock
  static const dspSampleHz = 32000; // native DSP output rate
  static const _spcCyclesPerSample = spcClockHz ~/ dspSampleHz; // 32

  int _spcCycleBudget = 0; // in units of (spc-cycles * mainCpuClockHz)
  int _dspCycleAccum = 0; // real spc-cycles toward the next output sample

  final _bufL = <double>[];
  final _bufR = <double>[];

  void reset() {
    spc.reset();
    dsp.reset();
    _spcCycleBudget = 0;
    _dspCycleAccum = 0;
    _bufL.clear();
    _bufR.clear();
  }

  /// call from the main bus when the 65816 writes $2140-2143.
  void mainCpuWrite(int port, int val) => spc.mainCpuWrite(port, val);

  /// call from the main bus when the 65816 reads $2140-2143.
  int mainCpuRead(int port) => spc.mainCpuRead(port);

  /// advances the APU by [mainCycles] main-CPU cycles (clocked at
  /// [mainCpuClockHz]).
  void exec(int mainCycles, int mainCpuClockHz) {
    _spcCycleBudget += mainCycles * spcClockHz;
    while (_spcCycleBudget >= mainCpuClockHz) {
      final before = spc.cycle;
      if (!spc.exec()) break; // unimplemented opcode: stop advancing
      final spent = spc.cycle - before;
      _spcCycleBudget -= spent * mainCpuClockHz;
      _tickDsp(spent);
    }
  }

  void _tickDsp(int spcCycles) {
    _dspCycleAccum += spcCycles;
    while (_dspCycleAccum >= _spcCyclesPerSample) {
      _dspCycleAccum -= _spcCyclesPerSample;
      final (l, r) = dsp.mixSample();
      _bufL.add(l);
      _bufR.add(r);
    }
  }

  /// returns accumulated samples as an interleaved stereo Float32List and
  /// clears the internal buffer. empty if nothing has accumulated yet.
  Float32List flush() {
    final n = _bufL.length;
    final out = Float32List(n * 2);
    for (int i = 0; i < n; i++) {
      out[i * 2] = _bufL[i];
      out[i * 2 + 1] = _bufR[i];
    }
    _bufL.clear();
    _bufR.clear();
    return out;
  }
}
