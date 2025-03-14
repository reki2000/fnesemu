part of 'gpu.dart';

extension GpuRenderer on Gpu {
  // Pre-calculated constants
  static const int alphaChannel = 0xff000000;

  // Lookup table for faster color conversion
  static final _rgb15ToRgb32 = List<int>.generate(32768, (i) {
    final int r = ((i >> 10) & 0x1f) << 3;
    final int g = ((i >> 5) & 0x1f) << 3 << 8;
    final int b = (i & 0x1f) << 3 << 16;
    return alphaChannel | r | g | b;
  });

  void renderScanline() {
    int bufIndex = scanline * width;
    final y = startDisplayY + scanline;

    // Choose appropriate rendering method based on color depth
    if (y < 512) {
      int fbIndex = y * 2048;

      if (isRgb24) {
        for (int x = 0; x < width; x++) {
          buffer[bufIndex++] = alphaChannel |
              (frameBuffer[fbIndex] << 16) | // B
              (frameBuffer[fbIndex + 1] << 8) | // G
              frameBuffer[fbIndex + 2]; // R
          fbIndex += 3;
        }
      } else {
        fbIndex += startDisplayX * 2;
        for (int x = 0; x < width; x++) {
          buffer[bufIndex++] = _rgb15ToRgb32[frameBuffer.getUInt16BE(fbIndex)];
          fbIndex += 2;
        }
      }
    }

    scanline++;
    // Reset scanline at the end of frame
    if (scanline == Gpu.scanlinesInFrame) {
      scanline = 0;
    }
  }
}
