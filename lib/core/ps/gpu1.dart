part of 'gpu.dart';

extension Gpu1 on Gpu {
  void writeGp1(int value) {
    final cmd = gp0 >> 24;
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
        status = status.setMasked(0x60000000, value << 29);

      case 0x05: // set drawing area top left
        startDisplayX = gp0 & 0x3ff;
        startDisplayY = gp0 >> 10 & 0x3ff;

      case 0x08: // display mode
        displayMode = gp0 & 0x7f;
        status = status & ~0x7f40 |
            value << 9 & 0x7e00 |
            value << 10 & 0x0100 |
            value << 7 & 0x0040;
        width = [256, 320, 512, 640][displayMode & 0x03];

      case >= 0x10 && < 0x20: // read gpu internal register
        switch (value & 0x07) {
          case 0x02: //  Read Texture Window setting
            readValue = 0;
          case 0x03: // Read Draw area top left
            readValue = 0;
          case 0x04: // Read Draw area bottom right
            readValue = 0;
          case 0x05: //  Read Draw offset
            readValue = 0;
        }

      default:
        debugLog("unknown GP1 command: ${value.hex32}");
    }
  }
}
