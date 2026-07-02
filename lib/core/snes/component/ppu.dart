import 'dart:typed_data';

/// milestone 2 placeholder PPU. produces a fixed blank frame so the Core's
/// imageBuffer() pipeline works. real BG/sprite/Mode7 rendering is milestone 3.
class Ppu {
  static const width = 256;
  static const height = 224;

  final buffer = Uint32List(width * height);

  Ppu() {
    reset();
  }

  void reset() {
    buffer.fillRange(0, buffer.length, 0xff202020); // opaque dark gray (ARGB)
  }

  /// advance one scanline. no-op until the renderer lands.
  void execScanline(int line) {}
}
