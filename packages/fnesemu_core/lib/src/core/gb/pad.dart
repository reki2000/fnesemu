import '../../pad_button.dart';
import '../../pad_source.dart';
import '../../util/int.dart';
import 'bus.dart';

/// joypad register P1 (FF00)
class Pad {
  final Bus _bus;

  static const select = PadButton("Select");
  static const start = PadButton("Start");
  static const b = PadButton("B");
  static const a = PadButton("A");

  final buttons = const [
    PadButton.up,
    PadButton.down,
    PadButton.left,
    PadButton.right,
    select,
    start,
    b,
    a,
  ];

  /// where the held buttons are read from, set by the core
  PadSource source = const NoPadSource();

  int _select = 0x30;

  // the levels last seen by [poll]: directions in bits 7-4, actions in 3-0
  int _sampled = 0xff;

  Pad(this._bus);

  void reset() {
    _select = 0x30;
    _sampled = _levels();
  }

  // active low bits: right left up down / a b select start
  int get _directions => _levels() >> 4;
  int get _actions => _levels() & 0x0f;

  int _levels() {
    var v = 0xff;
    if (source.isPressed(0, PadButton.right)) v &= ~0x10;
    if (source.isPressed(0, PadButton.left)) v &= ~0x20;
    if (source.isPressed(0, PadButton.up)) v &= ~0x40;
    if (source.isPressed(0, PadButton.down)) v &= ~0x80;
    if (source.isPressed(0, a)) v &= ~0x01;
    if (source.isPressed(0, b)) v &= ~0x02;
    if (source.isPressed(0, select)) v &= ~0x04;
    if (source.isPressed(0, start)) v &= ~0x08;
    return v;
  }

  /// samples the buttons, and requests the joypad interrupt when one of them
  /// went down since the last sample. the core calls it once per scanline.
  void poll() {
    final levels = _levels();
    if (_sampled & ~levels != 0) _bus.requestInterrupt(Bus.intJoypad);
    _sampled = levels;
  }

  int read() {
    var v = 0x0f;
    if (!_select.bit4) {
      v &= _directions;
    }
    if (!_select.bit5) {
      v &= _actions;
    }
    return 0xc0 | _select | v;
  }

  void write(int data) => _select = data & 0x30;
}
