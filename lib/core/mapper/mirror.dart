/// mirroring setting for PPU name table
class Mirror {
  //                0x2000/0x2400 0x2800/0x2c00
  // Vertical       0x2000 0x2400 0x2000 0x2400  A/A B/B mask: 0x7ff set: 0
  // Horizontal     0x2000 0x2000 0x2400 0x2400  A/B A/B mask: 0xbff set: 0
  // OneScreenLow   0x2000 0x2000 0x2000 0x2000  A/A A/A mask: 0x3ff set: 0
  // OneScreenHigh  0x2400 0x2400 0x2400 0x2400  B/B B/B mask: 0x3ff set: 0x400
  final int _mask;
  final int _on;
  final String _name;

  Mirror({required int mask, required int on, required String name})
      : _mask = mask,
        _on = on,
        _name = name;

  static final vertical = Mirror(mask: 0x17ff, on: 0, name: "v ");
  static final horizontal = Mirror(mask: 0x1bff, on: 0, name: "h ");
  static final oneScreenLow = Mirror(mask: 0x13ff, on: 0, name: "1l");
  static final oneScreenHigh = Mirror(mask: 0x13ff, on: 0x400, name: "1h");

  int mask(int addr) => addr & _mask | _on;

  String get name => _name;
}
