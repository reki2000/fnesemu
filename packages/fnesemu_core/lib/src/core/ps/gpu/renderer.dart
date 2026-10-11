part of 'gpu.dart';

extension GpuRenderer on Gpu {
  // Pre-calculated constants
  static const int alphaChannel = 0xff000000;

  // Lookup table for faster color conversion
  static final c15ToAbgr32 = Uint32List.fromList(List<int>.generate(32768, (i) {
    final int b = i.shr10.mask5.shl3.shl16;
    final int g = i.shr5.mask5.shl3.shl8;
    final int r = (i >> 0).mask5.shl3 << 0;
    return alphaChannel | r | g | b;
  }));

  @pragma('vm:unsafe:no-bounds-checks')
  void renderScanline() {
    final line = height == 240 ? scanline : scanline * 2 + (isOddFrame ? 1 : 0);
    int bufIndex = width * line;

    // the output starts at the first visible tv line (16 on NTSC); the display
    // range (GP1(07h)) decides where in it the picture is placed. a 224 line
    // picture (y1 = 24) is centered with 8 black lines above and below
    final top = isPal ? 0 : displayY1 - 16;
    final rel = scanline - top; // line inside the display range
    final fbY = (startDisplayY +
            (height == 240 ? rel : rel * 2 + (isOddFrame ? 1 : 0))).mask9;

    if (scanline < 240) {
      if (status.bit23 || rel < 0 || rel >= displayY2 - displayY1) {
        // display disabled or out of display range
        buffer.fillRange(bufIndex, bufIndex + width, alphaChannel);
      } else if (isRgb24) {
        final fbIndex = 2048 * fbY;
        int x8 = startDisplayX.shl1;
        for (int x = 0; x < width; x++) {
          buffer[bufIndex++] = alphaChannel |
              frameBuffer[fbIndex + x8.mask11] | // R
              frameBuffer[fbIndex + (x8 + 1).mask11].shl8 | // G
              frameBuffer[fbIndex + (x8 + 2).mask11].shl16; // B
          x8 += 3;
        }
      } else {
        final fbIndex = 1024 * fbY;
        final buffer = this.buffer, fb = frameBuffer16, table = c15ToAbgr32;
        final startX = startDisplayX;
        for (int x = 0; x < width; x++) {
          buffer[bufIndex++] =
              table[fb[fbIndex + (startX + x).mask10].mask15];
        }
      }
    }

    scanline++;

    if (scanline == Gpu.scanlinesInFrame - 20) {
      bus.timer.startVBlank();
      // the field flag toggles every frame while the vertical interlace flag
      // is set, even in the 240 line mode (games wait for it to change)
      isOddFrame = (height == 480 || status.bit22) ? !isOddFrame : false;
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
