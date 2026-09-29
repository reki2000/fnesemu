part of 'gpu.dart';

extension Gpu1 on Gpu {
  static const xMask = 0x3ff;
  static const yMask = 0x1ff;

  void writeGp1(int value) {
    final cmd = value.shr24;
    switch (cmd & 0x3f) {
      case 0x00: // reset
        status = 0x00802000; // display disabled, interlace field
        readValue = 0;
        cmdSize = 0;
        irq1 = false;
        vramToCpuReady = false;

        textureMaskX = textureMaskY = textureOffsetX = textureOffsetY = 0;
        textureMaskX2 = textureMaskY2 = 0xff;
        textureOffsetX2 = textureOffsetY2 = 0;
        drawingX1 = drawingY1 = drawingX2 = drawingY2 = 0;
        drawingOffsetX = drawingOffsetY = 0;

        startDisplayX = startDisplayY = 0;
        displayX1 = 0x200;
        displayX2 = 0x200 + 256 * 10;
        displayY1 = 0x10;
        displayY2 = 0x10 + 240;
        writeGp1(0x08000000);

      case 0x01: // reset command buffer
        cmdSize = 0;
        vramToCpuReady = false;

      case 0x02: // acknowledge interrupt
        irq1 = false;
      //bus.resetIrq(Interrupt.gpu);

      case 0x03: // display enable (0: on, 1: off)
        status = status.setBit(23, value.bit0);

      case 0x04: // dma direction / start address
        status = status.masked(0x60000000, value.shl29);

      case 0x05: // set drawing area top left
        startDisplayX = value & xMask;
        startDisplayY = value.shr10 & yMask;

      case 0x06: // set drawing range x
        displayX1 = value.mask12;
        displayX2 = value.shr12.mask12;

      case 0x07: // set drawing range y
        displayY1 = value.mask10;
        displayY2 = value.shr10.mask10;
        break;

      case 0x08: // display mode
        displayMode = value & 0x7f;
        status = status
            .masked(0x7e0000, value.shl17)
            .setBit(16, value.bit6)
            .setBit(14, value.bit7);

        width = value.bit6 ? 368 : [256, 320, 512, 640][displayMode & 0x03];

        dotClockDivider =
            7 * (value.bit6 ? 7 : [10, 8, 5, 4][displayMode & 0x03]);

        height = (value & 0x24 == 0x24) ? 480 : 240;
        if (buffer.length != width * height) {
          buffer = Uint32List(width * height);
        }

      case 0x09: // allow texture disable
        textureDisableAllowed = value.bit0;

      case >= 0x10 && < 0x20: // read gpu internal register
        switch (value & 0x07) {
          case 0x02: //  Read Texture Window setting
            readValue = textureMaskX |
                textureMaskY.shl5 |
                textureOffsetX.shl10 |
                textureOffsetY.shl15;
          case 0x03: // Read Draw area top left
            readValue = drawingX1 | drawingY1.shl10;
          case 0x04: // Read Draw area bottom right
            readValue = drawingX2 | drawingY2.shl10;
          case 0x05: //  Read Draw offset
            readValue = drawingOffsetX.mask11 | drawingOffsetY.mask11.shl11;
          case 0x07: // Read GPU type
            readValue = 2;
        }

      default:
        debugLog("unknown GP1 command: ${value.x8}");
    }
  }
}
