// Dart imports:
import 'dart:developer';
import 'dart:typed_data';

// Project imports:
import 'bus.dart';
import 'ppu_render.dart';
import 'util.dart';

class Ppu {
  late final Bus bus;

  int ctl1 = 0;
  int ctl2 = 0;
  int status = 0;
  int objAddr = 0;

  int scrollX = 0; // for debug
  int scrollY = 0; // for debug

  int tmpVramAddr = 0;
  int vramAddr = 0;
  int fineX = 0;
  bool first = true;

  int vramBuffer = 0;

  int scanLine = 0;

  int cycle = 0;

  final objRam = List<int>.filled(0x100, 0, growable: false);

  void onDMA(List<int> data) {
    for (int i = 0; i < 256; i++) {
      objRam[objAddr] = data[i];
      objAddr++;
      objAddr &= 0xff;
    }
  }

  // ppu control 1
  bool nmiOnVBlank() => ctl1 & 0x80 != 0;
  bool ppuMasterSlave() => ctl1 & 40 != 0;
  bool objSize() => ctl1 & 0x20 != 0;
  bool bgTable() => ctl1 & 0x10 != 0;
  bool objTable() => ctl1 & 0x08 != 0;
  bool vramIncrement() => ctl1 & 0x04 != 0;
  int baseNameAddr() => ctl1 & 0x03;

  // ppu control 2
  bool strongRed() => ctl2 & 0x80 != 0;
  bool strongGreen() => ctl2 & 0x40 != 0;
  bool strongBlue() => ctl2 & 0x20 != 0;
  bool showSprite() => ctl2 & 0x10 != 0;
  bool showBg() => ctl2 & 0x08 != 0;
  bool clipLeftEdgeSprite() => ctl2 & 0x04 == 0;
  bool clipLeftEdgeBg() => ctl2 & 0x02 == 0;
  bool colorMode() => ctl2 & 0x01 != 0;

  // status register
  set isVBlank(bool on) {
    if (on) {
      status |= 0x80;
    } else {
      status &= ~0x80;
    }
  }

  bool get isVBlank => (status & 0x80) != 0;

  set detectObj0(bool on) {
    if (on) {
      status |= 0x40;
    } else {
      status &= ~0x40;
    }
  }

  void write(int reg, int val) {
    switch (reg) {
      case 0x2000: // ppu control 1
        final nmiDisabled = !nmiOnVBlank();
        ctl1 = val;
        if (isVBlank && nmiDisabled && nmiOnVBlank()) {
          bus.onNMI();
        }
        tmpVramAddr = (tmpVramAddr & ~0x0c00) | (val & 0x03) << 10;
        break;
      case 0x2001: // ppu control 2
        ctl2 = val;
        break;
      case 0x2002: // status
        break;
      case 0x2003: // sprite address
        objAddr = val;
        break;
      case 0x2004: // sprite access
        objRam[objAddr] = val;
        objAddr++;
        objAddr &= 0xff;
        break;
      case 0x2005: // scroll
        if (first) {
          scrollX = val;
          tmpVramAddr = (tmpVramAddr & ~0x1f) | (val >> 3);
          fineX = val & 0x07;
          first = false;
        } else {
          scrollY = val;
          tmpVramAddr = (tmpVramAddr & ~0xf3e0) |
              ((val >> 3) << 5) |
              ((val & 0x07) << 12);
          first = true;
        }
        break;
      case 0x2006: // vram address
        if (first) {
          tmpVramAddr = (val & 0x3f) << 8 | tmpVramAddr & 0xff;
          first = false;
        } else {
          tmpVramAddr = (tmpVramAddr & 0xff00) | val;
          vramAddr = tmpVramAddr;
          first = true;
        }
        break;
      case 0x2007: // vram access
        writeVram(vramAddr, val);
        vramAddr += vramIncrement() ? 32 : 1;
        break;

      default:
        log("Unsupported ppu write at 0x${reg.toRadixString(16).padLeft(4, '0')}");
        return;
    }
  }

  int read(int reg) {
    switch (reg) {
      case 0x2002:
        first = true;
        final _status = status;
        isVBlank = false;
        return _status;
      case 0x2007:
        var data = vramBuffer;
        vramBuffer = readVram(vramAddr);
        if (0x3f00 <= vramAddr && vramAddr <= 0x3fff) {
          data = vramBuffer;
        }
        vramAddr += vramIncrement() ? 32 : 1;
        return data;

      default:
        log("Unsupported ppu read at 0x${reg.toRadixString(16).padLeft(4, '0')}");
        return 0;
    }
  }

  int readVram(int addr) {
    if (addr == 0x3f10 || addr == 0x3f14 || addr == 0x3f18 || addr == 0x3f1c) {
      addr &= 0x3f0f;
    }
    return bus.readVram(addr);
  }

  void writeVram(int addr, int val) {
    if (addr == 0x3f10 || addr == 0x3f14 || addr == 0x3f18 || addr == 0x3f1c) {
      addr &= 0x3f0f;
    }
    bus.writeVram(addr, val);
  }

  final buffer = Uint8List.fromList(
      List.filled(screenWidth * screenHeight * 4, 0, growable: false));

  void exec() {
    if (scanLine < 240) {
      renderLine();
      scanLine++;
      return;
    }

    scanLine++;

    if (scanLine == 241) {
      isVBlank = true;
    } else if (scanLine == 242) {
      if (nmiOnVBlank() && isVBlank) {
        bus.onNMI();
      }
    } else if (scanLine == 261) {
      detectObj0 = false;
      isVBlank = false;
      //renderLine();
    } else if (scanLine == 262) {
      scanLine = 0;
    }

    cycle += 341;
  }
}