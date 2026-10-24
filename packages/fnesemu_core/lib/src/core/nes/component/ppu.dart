import 'dart:typed_data';

import '../../../util/debug.dart';
import '../../../util/int.dart';
import '../constants.dart' as hardware;
import '../mapper/mapper.dart';
import 'bus.dart';
import 'ppu_render.dart';

final _log = DebugLog('nes.ppu');

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

  final spriteLine = Uint16List(256);

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
  bool nmiOnVBlank() => ctl1.bit7;
  bool ppuMasterSlave() => ctl1.bit6;
  bool objSize16() => ctl1.bit5;
  bool bgTable() => ctl1.bit4;
  bool objTable() => ctl1.bit3;
  bool vramIncrement() => ctl1.bit2;
  int baseNameAddr() => ctl1.mask2;

  // ppu control 2
  bool strongRed() => ctl2.bit7;
  bool strongGreen() => ctl2.bit6;
  bool strongBlue() => ctl2.bit5;
  bool showSprite() => ctl2.bit4;
  bool showBg() => ctl2.bit3;
  bool clipLeftEdgeSprite() => !ctl2.bit2;
  bool clipLeftEdgeBg() => !ctl2.bit1;
  bool colorMode() => ctl2.bit0;

  // status register
  set isVBlank(bool on) {
    if (on) {
      status |= 0x80;
    } else {
      status &= ~0x80;
    }
  }

  bool get isVBlank => status.bit7;

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
        bus.mapper.ppuCtl = val;
        if (isVBlank && nmiDisabled && nmiOnVBlank()) {
          bus.onNmi();
        }
        // t: ...GH.. ........ <- d: ......GH
        //    <used elsewhere> <- d: ABCDEF..
        tmpVramAddr = (tmpVramAddr & ~0x0c00) | val.mask2.shl10;
        break;

      case 0x2001: // ppu control 2
        ctl2 = val;
        bus.mapper.ppuMask = val;
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
          tmpVramAddr = (tmpVramAddr & ~0x1f) | val.shr3;
          fineX = val.mask3;
          first = false;
        } else {
          scrollY = val;
          // t: FGH..AB CDE..... <- d: ABCDEFGH
          tmpVramAddr =
              (tmpVramAddr & ~0x73e0) | val.shr3.shl5 | val.mask3.shl12;
          first = true;
        }
        break;

      case 0x2006: // vram address
        if (first) {
          // t: .CDEFGH ........ <- d: ..CDEFGH
          //        <unused>     <- d: AB......
          // t: Z...... ........ <- 0 (bit Z is cleared)
          tmpVramAddr = val.mask6.shl8 | tmpVramAddr.mask8;
          first = false;
        } else {
          // t: ....... ABCDEFGH <- d: ABCDEFGH
          // v: <...all bits...> <- t: <...all bits...>
          tmpVramAddr = (tmpVramAddr & 0xff00) | val;
          vramAddr = tmpVramAddr;
          bus.mapper.ppuAddressBus(vramAddr.mask14);
          first = true;
        }
        break;

      case 0x2007: // vram access
        bus.mapper.fetchPhase = Mapper.fetchCpu;
        bus.mapper.ppuAddressBus(vramAddr.mask14);
        writeVram(vramAddr.mask14, val);
        bus.mapper.fetchPhase = Mapper.fetchBg;
        vramAddr = (vramAddr + (vramIncrement() ? 32 : 1)).mask15;
        bus.mapper.ppuAddressBus(vramAddr.mask14);
        break;

      default:
        _log.warnc(() => "Unsupported ppu write at 0x${reg.x4}");
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

      case 0x2004:
        return objRam[objAddr];

      case 0x2007:
        final addr = vramAddr.mask14;
        bus.mapper.fetchPhase = Mapper.fetchCpu;
        bus.mapper.ppuAddressBus(addr);
        var data = readVram(addr);
        if (addr < 0x3f00) {
          final swap = vramBuffer;
          vramBuffer = data;
          data = swap;
        } else {
          // palette is returned directly, the buffer gets the nametable below
          vramBuffer = readVram(addr - 0x1000);
        }
        bus.mapper.fetchPhase = Mapper.fetchBg;
        vramAddr = (vramAddr + (vramIncrement() ? 32 : 1)).mask15;
        bus.mapper.ppuAddressBus(vramAddr.mask14);
        return data;

      default:
        _log.warnc(() => "Unsupported ppu read at 0x${reg.x4}");
        return 0;
    }
  }

  int readVram(int addr) {
    if (addr < 0x3f00) {
      return bus.readVram(addr);
    }

    // 0x3f10/14/18/1c (and their mirrors) are mirrors of 0x3f00/04/08/0c
    if (addr & 0x13 == 0x10) {
      addr &= ~0x10;
    }
    return palette[addr.mask5];
  }

  void writeVram(int addr, int val) {
    if (addr < 0x3f00) {
      bus.writeVram(addr, val);
      return;
    }

    if (addr & 0x13 == 0x10) {
      addr &= ~0x10;
    }
    palette[addr.mask5] = val;
  }

  final buffer = Uint32List(hardware.imageWidth * hardware.imageHeight);

  void exec() {
    if (scanLine < 240) {
      renderLine();
      scanLine++;
      return;
    }

    // renderLine() fetches the sprites of the previous line, so the sprite
    // fetches at dot 257-320 of line 239 are done here. mappers like MMC3
    // count the A12 edges.
    if (scanLine == 240 && (showBg() || showSprite())) {
      readVram(objTable() || objSize16() ? 0x1000 : 0x0000);
    }

    scanLine++;

    if (scanLine == 241) {
      isVBlank = true;
      if (nmiOnVBlank() && isVBlank) {
        bus.onNmi();
      }
    } else if (scanLine == hardware.scanlinesInFrame - 1) {
      detectObj0 = false;
      isVBlank = false;

      // dot 1-256 of the pre-render line: background fetches
      if (showBg() || showSprite()) {
        readVram(bgTable() ? 0x1000 : 0x0000);
      }
    } else if (scanLine == hardware.scanlinesInFrame) {
      scanLine = 0;
    }

    cycle += 341;
  }
}
