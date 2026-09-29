part of 'gpu.dart';

extension GpuRenderer on Gpu {
  // Pre-calculated constants
  static const int alphaChannel = 0xff000000;

  // Lookup table for faster color conversion
  static final c15ToAbgr32 = List<int>.generate(32768, (i) {
    final int b = (i.shr10 & 0x1f).shl3.shl16;
    final int g = (i.shr5 & 0x1f).shl3.shl8;
    final int r = ((i >> 0) & 0x1f).shl3 << 0;
    return alphaChannel | r | g | b;
  });

  void renderScanline() {
    final line = height == 240 ? scanline : scanline * 2 + (isOddFrame ? 1 : 0);
    int bufIndex = width * line;
    final fbY = (startDisplayY + line) & 0x1ff;

    if (scanline < 240) {
      if (status.bit23 || scanline >= displayY2 - displayY1) {
        // display disabled or out of display range
        buffer.fillRange(bufIndex, bufIndex + width, alphaChannel);
      } else if (isRgb24) {
        final fbIndex = 2048 * fbY;
        int x8 = startDisplayX.shl1;
        for (int x = 0; x < width; x++) {
          buffer[bufIndex++] = alphaChannel |
              frameBuffer[fbIndex + (x8 & 0x7ff)] | // R
              frameBuffer[fbIndex + ((x8 + 1) & 0x7ff)].shl8 | // G
              frameBuffer[fbIndex + ((x8 + 2) & 0x7ff)].shl16; // B
          x8 += 3;
        }
      } else {
        final fbIndex = 1024 * fbY;
        for (int x = 0; x < width; x++) {
          buffer[bufIndex++] = c15ToAbgr32[
              frameBuffer16[fbIndex + ((startDisplayX + x) & 0x3ff)] & 0x7fff];
        }
      }
    }

    scanline++;

    if (scanline == Gpu.scanlinesInFrame - 20) {
      bus.timer.startVBlank();
      isOddFrame = (height == 480) ? !isOddFrame : false;
      isVblank = true;
      bus.setIrq(Interrupt.vBlank); // vblank irq at the beginning of vblank
    }

    // Reset scanline at the end of frame
    if (scanline == Gpu.scanlinesInFrame) {
      bus.timer.endVBlank();
      // bus.resetIrq(Interrupt.vBlank);
      scanline = 0;
      isVblank = false;
      frame++;
      debugCmdIndexInFrame = 0;
    }
  }
}
