/// mirroring setting for PPU name table
class Mirror {
  //                0x2000-0x2400/0x2800-0x2c00
  // Vertical       0x2000 0x2400 0x2000 0x2400  A-B/A-B
  // Horizontal     0x2000 0x2000 0x2400 0x2400  A-A/B-B
  // OneScreenLow   0x2000 0x2000 0x2000 0x2000  A-A/A-A
  // OneScreenHigh  0x2400 0x2400 0x2400 0x2400  B-B/B-B
  final int Function(int) mask;
  final String name;
  final bool isExternal;

  Mirror(
    this.mask, {
    required this.name,
    this.isExternal = false,
  });

  static final vertical = Mirror((v) => v & ~0x800, name: "v ");
  static final horizontal =
      Mirror((v) => v & ~0xc00 | ((v & 0x800) >> 1), name: "h ");
  static final oneScreenLow = Mirror((v) => v & ~0xc00, name: "1l");
  static final oneScreenHigh = Mirror((v) => v & ~0xc00 | 0x400, name: "1h");

  static final external = Mirror((v) => v, name: "ex", isExternal: true);
}
