import '../../../pad_button.dart';
import '../../../pad_source.dart';
import '../../../util/int.dart';

/// SNES standard pad. bit layout of the auto-joypad word ($4219$4218):
/// B Y Select Start Up Down Left Right A X L R - - - -  (b15..b0)
class SnesPad {
  static const _b = PadButton("B");
  static const _y = PadButton("Y");
  static const _select = PadButton("Select");
  static const _start = PadButton("Start");
  static const _a = PadButton("A");
  static const _x = PadButton("X");
  static const _l = PadButton("L");
  static const _r = PadButton("R");

  static const buttons = [
    PadButton.up,
    PadButton.down,
    PadButton.left,
    PadButton.right,
    // in the order of the keys A S Z X C Q W E R D
    _y,
    _b,
    _select,
    PadButton.none,
    _start,
    _l,
    _x,
    _r,
    PadButton.none,
    _a,
  ];

  static const _bit = {
    _b: 15,
    _y: 14,
    _select: 13,
    _start: 12,
    PadButton.up: 11,
    PadButton.down: 10,
    PadButton.left: 9,
    PadButton.right: 8,
    _a: 7,
    _x: 6,
    _l: 5,
    _r: 4,
  };

  PadSource source;

  SnesPad([this.source = const NoPadSource()]);

  /// the held buttons of pad 1 as the auto-joypad word
  int get state1 {
    var word = 0;
    for (final e in _bit.entries) {
      if (source.isPressed(0, e.key)) word |= 1 << e.value;
    }
    return word;
  }

  // the serial shift register of pad 1, read through $4016. It shifts in 1s,
  // so a standard pad reads 1 after its 16 bits.
  int _shift1 = 0;
  bool _latch = false;

  /// $4016 write: bit 0 latches the buttons into the shift register
  void writeLatch(int data) {
    _latch = data.bit0;
    if (_latch) _shift1 = state1;
  }

  /// $4016 read: bit 0 is the next bit of pad 1
  int readSerial1() {
    if (_latch) return state1.bit15 ? 1 : 0;
    final bit = _shift1.bit15 ? 1 : 0;
    _shift1 = (_shift1.shl1 | 1).mask16;
    return bit;
  }

  /// the auto-joypad read at vblank shifts out all 16 bits
  void autoRead() {
    _shift1 = 0xffff;
  }
}
