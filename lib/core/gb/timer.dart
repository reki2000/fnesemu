import 'package:fnesemu/util/int.dart';

import 'bus.dart';

/// DIV / TIMA / TMA / TAC. TIMA counts falling edges of a bit of the
/// internal 16bit divider, so writing DIV or TAC may increment TIMA.
class Timer {
  final Bus _bus;

  int counter = 0; // internal divider, DIV is the upper 8 bits
  int tima = 0;
  int tma = 0;
  int tac = 0;

  bool _reloading = false;

  static const _bits = [1 << 9, 1 << 3, 1 << 5, 1 << 7];

  Timer(this._bus);

  void reset() {
    counter = 0xabcc;
    tima = 0;
    tma = 0;
    tac = 0xf8;
    _reloading = false;
  }

  bool _signal(int cnt) => tac.bit2 && cnt & _bits[tac.mask2] != 0;

  void _incTima() {
    tima = (tima + 1).mask8;
    if (tima == 0) {
      _reloading = true;
    }
  }

  void _setCounter(int value) {
    final old = counter;
    counter = value.mask16;

    if (_signal(old) && !_signal(counter)) {
      _incTima();
    }

    // frame sequencer of the sound unit is clocked by bit 12 falling edge
    if (old.bit12 && !counter.bit12) {
      _bus.apu.clockFrameSequencer();
    }
  }

  /// one machine cycle
  void tick() {
    if (_reloading) {
      _reloading = false;
      tima = tma;
      _bus.requestInterrupt(Bus.intTimer);
    }

    _setCounter(counter + 4);
  }

  void writeDiv() => _setCounter(0);

  int read(int addr) => switch (addr) {
        0xff04 => counter.shr8,
        0xff05 => tima,
        0xff06 => tma,
        _ => tac | 0xf8,
      };

  void write(int addr, int data) {
    switch (addr) {
      case 0xff04:
        writeDiv();
      case 0xff05:
        tima = data;
        _reloading = false;
      case 0xff06:
        tma = data;
      case 0xff07:
        final oldSignal = _signal(counter);
        tac = data.mask3;
        if (oldSignal && !_signal(counter)) {
          _incTima();
        }
    }
  }
}
