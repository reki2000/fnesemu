part of 'gpu.dart';

extension GpuRenderer on Gpu {
  // Pre-calculated constants
  static const int alphaChannel = 0xff000000;

  // Lookup table for faster color conversion
  static final c15ToAbgr32 = List<int>.generate(32768, (i) {
    final int b = ((i >> 10) & 0x1f) << 3 << 16;
    final int g = ((i >> 5) & 0x1f) << 3 << 8;
    final int r = ((i >> 0) & 0x1f) << 3 << 0;
    return alphaChannel | r | g | b;
  });

  void renderScanline() {
    int bufIndex = width *
        (height == 480 ? (scanline * 2 + (isOddFrame ? 1 : 0)) : scanline);
    final y = startDisplayY + scanline;

    // Choose appropriate rendering method based on color depth
    if (y < 512) {
      int fbIndex =
          2048 * (y + (height == 240 ? 0 : (y + (isOddFrame ? 1 : 0))));

      if (isRgb24) {
        for (int x = 0; x < width; x++) {
          buffer[bufIndex++] = alphaChannel |
              frameBuffer[fbIndex] | // B
              frameBuffer[fbIndex + 1] << 8 | // G
              frameBuffer[fbIndex + 2] << 16; // R
          fbIndex += 3;
        }
      } else {
        for (int x = startDisplayX; x < width; x++) {
          buffer[bufIndex++] =
              c15ToAbgr32[frameBuffer.getUInt16LE(fbIndex + x * 2) & 0x7fff];
        }
      }
    }

    scanline++;
    // Reset scanline at the end of frame
    if (scanline == Gpu.scanlinesInFrame) {
      scanline = 0;
      isOddFrame = (height == 480) ? !isOddFrame : false;
    }
  }
}
