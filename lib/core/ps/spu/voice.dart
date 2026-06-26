import 'package:fnesemu/util/debug.dart';
import 'package:fnesemu/util/int.dart';

import 'spu.dart';

part 'adpcm.dart';

class Envelope {
  static const counterMax = 0x400000;

  final bool enabled;
  final int step;
  final int shift;
  final bool exponential;
  final bool decreasing;
  final bool negativePhase;
  final int couterDecrement;

  int counter = counterMax;

  Envelope(this.enabled, this.step, this.shift, this.exponential,
      this.decreasing, this.negativePhase, this.couterDecrement);

  factory Envelope.of(
      int step_, int shift_, bool exponential_, bool decreasing_,
      {bool negativePhase_ = false}) {
    final rawStep = 7 - step_;
    final baseStep = decreasing_ ^ negativePhase_
        ? -rawStep
        : rawStep; // +7,+6,+5,+4 => -8,-7,-6,-5
    final step = baseStep << (11 - shift_).max(0);
    final counterDecrement = 0x400000 >> (shift_ - 11).max(0);

    return Envelope(
      true,
      step,
      shift_,
      exponential_,
      decreasing_,
      false,
      counterDecrement,
    );
  }

  factory Envelope.none() => Envelope(false, 0, 0, false, false, false, 0);

  int apply(int current) {
    if (!enabled) return current;

    final dec = couterDecrement >>
        ((!decreasing && exponential && current > 0x6000) ? 2 : 0);

    counter = (counter - dec).max(0);

    if (counter > 0) {
      return current;
    }

    counter = counterMax;
    final applyStep =
        (decreasing && exponential) ? (step * current) >> 15 : step;
    final vol = (current + applyStep);

    return !decreasing
        ? vol.clip(-0x8000, 0x7fff)
        : negativePhase
            ? vol.clip(-0x8000, 0)
            : vol.max(0);
  }
}

class Voice {
  final int no;
  final Spu spu;
  Voice(this.spu, this.no);

  bool noise = false;
  bool pitchModulation = false;

  // Volume control

  final _volReg = [0, 0];
  final _vol = [0, 0]; // current volume
  final _volSweep = [Envelope.none(), Envelope.none()];

  int volume(int lr) => _volReg[lr];

  setVolume(int lr, int val) {
    _volReg[lr] = val;

    if (!val.bit15) {
      _vol[lr] = (val << 1).rel16;
      _volSweep[lr] = Envelope.none();
    } else {
      _volSweep[lr] = Envelope.of(
          val >> 8 & 0x3, val >> 2 & 0x1f, val.bit14, val.bit13,
          negativePhase_: val.bit6);
    }
  }

  // ADSR envelope control

  int adsr = 0;
  int adsrVolume = 0;

  Envelope envelope = Envelope.none();
  int sustainLevel = 0;
  int _adsrPhase = 0;

  void setAttackDecay(int v) => adsr = adsr.setL16(v);
  void setSustainRelease(int v) => adsr = adsr.setH16(v);

  // ADPCM decode control

  int startAddr = 0;
  int _repeatAddr = 0;

  bool _repeatAddrSet = false;
  int get repeatAddr => _repeatAddr;
  set repeatAddr(int value) {
    _repeatAddrSet = true;
    _repeatAddr = value;
  }

  int pitch = 0;

  int _addr = 0;
  bool endx = true;

  static const blockSize = 28;
  static const blockOldSize = 4;
  final _block = List<int>.filled(blockSize + blockOldSize, 0, growable: false);
  int _blockIndex = 0;

  int _counter = 0;

  int logCounter = 0;

  void reset() {
    _block.fillRange(0, _block.length, 0);
    _blockIndex = 0;
    _counter = 0;
    endx = false;
    envelope = Envelope.none();
    adsrVolume = 0;
    _adsrPhase = 0;
    repeatAddr = 0;
    _repeatAddrSet = false;
    _volSweep[0] = Envelope.none();
    _volSweep[1] = Envelope.none();
  }

  /// proceed to next sample
  (int, int, int) clock() {
    final step = pitch; // todo pitch modulation
    _counter += step.min(0x4000);

    _blockIndex += _counter >> 12;
    _counter &= 0xfff;

    if (_blockIndex >= blockSize) {
      decodeBlock();
      _blockIndex -= blockSize;
    }

    final i = _blockIndex + blockOldSize;
    final val = gaussian(_block[i], _block[i - 1], _block[i - 2], _block[i - 3],
        _counter >> 4 & 0xff);

    adsrVolume = envelope.apply(adsrVolume);

    switch (_adsrPhase) {
      case 1:
        if (adsrVolume == 0x7fff) {
          envelope = Envelope.of(0, adsr >> 4 & 0x0f, true, true); // decay
          _adsrPhase = 2;
        }
      case 2:
        if (adsrVolume <= sustainLevel) {
          envelope = Envelope.of(adsr >> 22 & 0x03, adsr >> 24 & 0x1f,
              adsr.bit31, adsr.bit30); // sustain
          _adsrPhase = 3;
        }
    }

    final adsrVal = val * adsrVolume ~/ 0x8000;

    for (int i = 0; i < 2; i++) {
      _vol[i] = _volSweep[i].apply(_vol[i]);
    }

    return (adsrVal * _vol[0] ~/ 0x8000, adsrVal * _vol[1] ~/ 0x8000, adsrVal);
  }

  void keyOn() {
    // debugLog(
    //     "SPU: keyOn  ch:$no addr:${startAddr.x6} pitch:${pitch.x6} vol:${_volReg[0].x4},${_volReg[1].x4} e:${adsr.x8}");
    _addr = startAddr;
    if (!_repeatAddrSet) {
      repeatAddr = startAddr;
    }

    decodeBlock();

    _blockIndex = 0;
    _counter = 0;

    envelope = Envelope.of(
        adsr >> 8 & 0x03, adsr >> 10 & 0x1f, adsr.bit15, false); // attack
    sustainLevel = ((adsr & 0xf) + 1) << 11;
    adsrVolume = 0;
    _adsrPhase = 1;

    endx = false;
  }

  void keyOff() {
    _adsrPhase = 4;
    envelope = Envelope.of(0, adsr >> 16 & 0x1f, adsr.bit21, true); // release

    // debugLog(
    //     "SPU: keyOff ch:$no addr:${startAddr.x6} pitch:${pitch.x6} vol:${_volReg[0].x4},${_volReg[1].x4} e:${adsr.x8}");
  }

  String dump() => "${no.d2}${endx ? "E" : "R"}:"
      "${_volReg[1].x4}${_volReg[0].x4}-"
      "${(startAddr >> 3).x4}${pitch.x4}-"
      "${adsr.x8}-"
      "${(_addr >> 3).x4}${adsrVolume.x4}";
}
