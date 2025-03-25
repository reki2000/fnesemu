part of 'gpu.dart';

extension Gpu1 on Gpu {
  static const xMask = 0x3ff;
  static const yMask = 0x1ff;

  void writeGp1(int value) {
    final cmd = value >> 24;
    switch (cmd & 0x3f) {
      case 0x00: // reset
        status = 0;
        readValue = 0;

      case 0x01: // reset command buffer
        cmdSize = 0;

      case 0x02: // acknowledge interrupt
        status = status.setBit(24, false);

      case 0x03: // display enable
        status = status.setBit(28, value.bit0);

      case 0x04: // dma direction / start address
        status = status.masked(0x60000000, value << 29);

      case 0x05: // set drawing area top left
        startDisplayX = value & xMask;
        startDisplayY = value >> 10 & yMask;

      case 0x06: // set drawing range x
        break;

      case 0x07: // set drawing range y
        break;

      case 0x08: // display mode
        displayMode = value & 0x7f;
        status = status
            .masked(0x7e00, value << 17)
            .setBit(16, value.bit6)
            .setBit(14, value.bit7);

        width = value.bit6 ? 368 : [256, 320, 512, 640][displayMode & 0x03];

        dotClockDivider =
            7 * (value.bit6 ? 7 : [10, 8, 5, 4][displayMode & 0x03]);

        height = (value & 0x24 == 0x24) ? 480 : 240;
        if (buffer.length != width * height) {
          buffer = Uint32List(width * height);
        }

      case >= 0x10 && < 0x20: // read gpu internal register
        switch (value & 0x07) {
          case 0x02: //  Read Texture Window setting
            readValue = textureMaskX | textureMaskY << 10;
          case 0x03: // Read Draw area top left
            readValue = drawingX1 | drawingY1 << 10;
          case 0x04: // Read Draw area bottom right
            readValue = drawingX2 | drawingY2 << 10;
          case 0x05: //  Read Draw offset
            readValue = drawingOffsetX | drawingOffsetY << 10;
        }

      default:
        debugLog("unknown GP1 command: ${value.hex32}");
    }
  }
}
