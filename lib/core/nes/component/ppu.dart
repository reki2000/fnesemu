// Dart imports:
import 'dart:developer';
import 'dart:typed_data';

// Project imports:
import '../../../util/util.dart';
import '../nes.dart';
import 'bus.dart';
import 'ppu_render.dart';

class Ppu {
  final Bus bus;

  Ppu(this.bus) {
    bus.ppu = this;
  }

  reset() {
    ctl1 = 0;
    ctl2 = 0;
    status = 0;
    objAddr = 0;
    scrollX = 0;
    scrollY = 0;
    tmpVramAddr = 0;
    vramAddr = 0;
    fineX = 0;
    first = true;
    vramBuffer = 0;
    scanLine = 0;
    cycle = 0;
  }

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

  final objRam = List<int>.filled(0x100, 0);

  final palette = List<int>.filled(0x20, 0);

  void onDMA(List<int> data) {
    for (int i = 0; i < 256; i++) {
      objRam[objAddr] = data[i];
      objAddr++;
      objAddr &= 0xff;
    }
  }

  // ppu control 1
  bool nmiOnVBlank() => bit7(ctl1);
  bool ppuMasterSlave() => bit6(ctl1);
  bool objSize16() => bit5(ctl1);
  bool bgTable() => bit4(ctl1);
  bool objTable() => bit3(ctl1);
  bool vramIncrement() => bit2(ctl1);
  int baseNameAddr() => ctl1 & 0x03;

  // ppu control 2
  bool strongRed() => bit7(ctl2);
  bool strongGreen() => bit6(ctl2);
  bool strongBlue() => bit5(ctl2);
  bool showSprite() => bit4(ctl2);
  bool showBg() => bit3(ctl2);
  bool clipLeftEdgeSprite() => !bit2(ctl2);
  bool clipLeftEdgeBg() => !bit1(ctl2);
  bool colorMode() => bit0(ctl2);

  // status register
  set isVBlank(bool on) {
    if (on) {
      status |= 0x80;
    } else {
      status &= ~0x80;
    }
  }

  bool get isVBlank => bit7(status);

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
          bus.onNmi();
        }
        // t: ...GH.. ........ <- d: ......GH
        //    <used elsewhere> <- d: ABCDEF..
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
          // t: ....... ...ABCDE <- d: ABCDE...
          // x:              FGH <- d: .....FGH
          tmpVramAddr = (tmpVramAddr & ~0x1f) | (val >> 3);
          fineX = val & 0x07;
          first = false;
        } else {
          scrollY = val;
          // t: FGH..AB CDE..... <- d: ABCDEFGH
          tmpVramAddr = (tmpVramAddr & ~0x73e0) |
              ((val >> 3) << 5) |
              ((val & 0x07) << 12);
          first = true;
        }
        break;

      case 0x2006: // vram address
        if (first) {
          // t: .CDEFGH ........ <- d: ..CDEFGH
          //        <unused>     <- d: AB......
          // t: Z...... ........ <- 0 (bit Z is cleared)
          tmpVramAddr = (val & 0x3f) << 8 | tmpVramAddr & 0xff;
          first = false;
        } else {
          // t: ....... ABCDEFGH <- d: ABCDEFGH
          // v: <...all bits...> <- t: <...all bits...>
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
        final status2 = status;
        isVBlank = false; // isVBlanks is a setter, changing status
        return status2;

      case 0x2007:
        var data = readVram(vramAddr);
        if (vramAddr < 0x3f00) {
          final swap = vramBuffer;
          vramBuffer = data;
          data = swap;
        }
        vramAddr += vramIncrement() ? 32 : 1;
        return data;

      default:
        log("Unsupported ppu read at 0x${reg.toRadixString(16).padLeft(4, '0')}");
        return 0;
    }
  }

  int readVram(int addr) {
    if (addr < 0x3f00) {
      return bus.readVram(addr);
    }

    if (addr == 0x3f10 || addr == 0x3f14 || addr == 0x3f18 || addr == 0x3f1c) {
      addr &= 0x3f0f;
    }
    return palette[addr & 0x1f];
  }

  void writeVram(int addr, int val) {
    if (addr < 0x3f00) {
      bus.writeVram(addr, val);
      return;
    }

    if (addr == 0x3f10 || addr == 0x3f14 || addr == 0x3f18 || addr == 0x3f1c) {
      addr &= 0x3f0f;
    }
    palette[addr & 0x1f] = val;
  }

  final buffer = Uint32List(Nes.imageWidth * Nes.imageHeight);

  void exec() {
    if (scanLine < 240) {
      renderLine();
      scanLine++;
      return;
    }

    scanLine++;

    if (scanLine == 241) {
      isVBlank = true;
      if (nmiOnVBlank() && isVBlank) {
        bus.onNmi();
      }
    } else if (scanLine == Nes.scanlinesInFrame_ - 1) {
      detectObj0 = false;
      isVBlank = false;
    } else if (scanLine == Nes.scanlinesInFrame_) {
      scanLine = 0;
    }

    cycle += 341;
  }
}
