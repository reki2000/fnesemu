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
    // if (status.bit23) {
    //   // Skip rendering if the status bit is set
    //   return;
    // }

    int bufIndex = width *
        (height == 240 ? scanline : (scanline * 2 + (isOddFrame ? 1 : 0)));
    final y = startDisplayY + scanline;
    final fbIndexY = height == 240 ? y : (y * 2 + (isOddFrame ? 1 : 0));

    // Choose appropriate rendering method based on color depth
    if (y < 512 && scanline < 240) {
      if (isRgb24) {
        int fbIndex = 2048 * fbIndexY;
        for (int x = 0; x < width; x++) {
          buffer[bufIndex++] = alphaChannel |
              frameBuffer[fbIndex] | // B
              frameBuffer[fbIndex + 1] << 8 | // G
              frameBuffer[fbIndex + 2] << 16; // R
          fbIndex += 3;
        }
      } else {
        final fbIndex = 1024 * fbIndexY;
        // debugLog(
        //     "GPU: renderScanline y:$y scanline:$scanline startDisplayX:$startDisplayX fbIndex:$fbIndex");
        for (int x = startDisplayX; x < width; x++) {
          buffer[bufIndex++] = c15ToAbgr32[frameBuffer16[fbIndex + x] & 0x7fff];
        }
      }
    }

    scanline++;

    if (scanline == Gpu.scanlinesInFrame - 20) {
      bus.timer.startVBlank();
      isOddFrame = (height == 480) ? !isOddFrame : false;
      isVblank = true;
    }

    // Reset scanline at the end of frame
    if (scanline == Gpu.scanlinesInFrame) {
      bus.setIrq(Interrupt.vBlank);
      bus.timer.endVBlank();
      // bus.resetIrq(Interrupt.vBlank);
      scanline = 0;
      isVblank = false;
      frame++;
    }
  }
}
