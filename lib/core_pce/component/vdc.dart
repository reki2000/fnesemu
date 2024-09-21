// Dart imports:
import 'package:fnesemu/core_pce/component/vdc_render.dart';

import '../../util.dart';
import 'bus.dart';
import 'cpu.dart';

class Vdc {
  final Bus bus;

  Vdc(this.bus) {
    bus.vdc = this;
  }

  String dump() {
    final scr =
        "x:${hex16(scrollX)} y:${hex8(scrollY)} rr:${hex16(rasterCompareRegister)} inc:${hex8(addrInc)}";
    final flags =
        "irq:${enableRasterCompareIrq ? 's' : '-'}${enableVBlank ? 'v' : '-'}${enalbeSpriteCollision ? 'c' : '-'}${enableSpriteOverflow ? 'o' : '-'}";
    final bg =
        "bg:${bgWidthMask + 1}x${bgHeightMask + 1} ${enableBg ? 'b' : '-'}${enableSprite ? 's' : '-'}";
    final line = " line: $scanLine ${VdcRenderer.renderLine}";
    return "vdc: $scr $flags $bg $line";
  }

  reset() {
    for (int i = 0; i < vram.length; i++) {
      vram[i] = 0;
    }

    for (int i = 0; i < colorTable.length; i++) {
      colorTable[i] = 0;
    }

    scanLine = 0;
    h = 0;

    status = 0;
    rasterCompareRegister = 0;
    controlRegister = 0;
    scrollX = 0;
    scrollY = 0;
    enableBg = false;
    enableSprite = false;
    enableVBlank = false;
    enableRasterCompareIrq = false;
    enalbeSpriteCollision = false;
    enableSpriteOverflow = false;
    writeLatch = 0;
    readLatch = 0;
    mawr = 0;
    marr = 0;
    addrInc = 0;
    reg = 0;
    vramDotWidth = 0;
    bgWidthBits = 5;
    bgHeightBits = 5;
    bgWidthMask = 0x1f;
    bgHeightMask = 0x1f;
    bgTreatPlane23Zero = false;
    dmaSrc = 0;
    dmaSrcDir = 0;
    dmaDst = 0;
    dmaDstDir = 0;
    dmaLen = 0;
    dma = false;
    enableDmaVramIrq = false;
    enableDmaSatIrq = false;
    dmaSrcSatb = 0;
    dmaSatb = false;
    dmaSatbAlways = false;
  }

  int scanLine = 0; // vertical counter
  int h = 0; // horizontal counter

  int reg = 0;

  int readLatch = 0;

  int mawr = 0;
  int marr = 0;
  int addrInc = 0;

  int scrollX = 0;
  int scrollY = 0;

  bool enableBg = false;
  bool enableSprite = false;

  bool enableVBlank = false;
  bool enableRasterCompareIrq = false;
  bool enalbeSpriteCollision = false;
  bool enableSpriteOverflow = false;

  int writeLatch = 0;

  int status = 0;

  static const statusBusy = 0x40;
  static const statusVBlank = 0x20; // vblank irq
  static const statusDmaVram = 0x10; // dma vram irq
  static const statusDmaSat = 0x08; // dma satb irq
  static const statusRasterCompare = 0x04; // raster compare
  static const statusSpriteOverflow = 0x02; // sprite overflow
  static const statusSpriteCollision = 0x01; // sprite collision

  int rasterCompareRegister = 0;

  int controlRegister = 0;

  int bgWidthBits = 5;
  int bgHeightBits = 5;

  int bgWidthMask = 0x1f;
  int bgHeightMask = 0x1f;

  bool bgTreatPlane23Zero = false;
  int vramDotWidth = 0;

  final vram = List<int>.filled(0x10000, 0); // 2 bytes per word

  final sat = List<int>.filled(0x100, 0);

  int readReg() {
    bus.pic.acknoledgeIrq1();

    final value = status;
    status = 0;
    return value;
  }

  int readLsb() {
    return readLatch & 0xff;
  }

  int readMsb() {
    final val = readLatch >> 8;
    marr = (marr + addrInc) & 0xffff;
    readLatch = vram[marr];
    return val;
  }

  writeReg(int val) {
    // print("writeReg: ${hex8(reg)}");
    reg = val & 0x1f;
  }

  writeLsb(int val) {
    // print("writeLsb: ${hex8(val)}");
    switch (reg) {
      case 0x00:
        mawr = mawr.withLowByte(val);
        break;
      case 0x01:
        marr = marr.withLowByte(val);
        break;
      case 0x02:
        writeLatch = writeLatch.withLowByte(val);
        break;

      case 0x05:
        enalbeSpriteCollision = val & 0x01 != 0;
        enableSpriteOverflow = val & 0x02 != 0;
        enableRasterCompareIrq = val & 0x04 != 0;
        enableVBlank = val & 0x08 != 0;

        enableSprite = val & 0x40 != 0;
        enableBg = val & 0x80 != 0;
        break;

      case 0x06:
        rasterCompareRegister = rasterCompareRegister.withLowByte(val);
        break;
      case 0x07:
        scrollX = scrollX.withLowByte(val);
        break;
      case 0x08:
        scrollY = scrollY.withLowByte(val);
        VdcRenderer.renderLine = scrollY;
        // print("scrollY LSB: ${hex8(val)} $scrollY");
        break;

      case 0x09:
        vramDotWidth = val & 0x03;
        bgWidthBits = switch (val & 0x30) {
          0x00 => 5,
          0x10 => 6,
          0x20 => 7,
          0x30 => 7,
          int() => throw UnimplementedError(),
        };
        bgWidthMask = (1 << bgWidthBits) - 1;

        bgHeightBits = switch (val & 0x40) {
          0x00 => 5,
          0x40 => 6,
          int() => throw UnimplementedError(),
        };
        bgHeightMask = (1 << bgHeightBits) - 1;

        bgTreatPlane23Zero = val & 0x80 == 0;
        // print(
        //     "bgTreatPlane23Zero: $bgTreatPlane23Zero, vramDotWidth:$vramDotWidth, bg: ${bgWidthMask + 1} x ${bgHeightMask + 1}");
        break;

      case 0x0f:
        enableDmaSatIrq = bit0(val);
        enableDmaVramIrq = bit1(val);
        dmaSrcDir = bit2(val) ? -1 : 1;
        dmaDstDir = bit3(val) ? -1 : 1;
        dmaSatbAlways = bit4(val);
        break;

      case 0x10:
        dmaSrc = dmaSrc.withLowByte(val);
        break;
      case 0x11:
        dmaDst = dmaDst.withLowByte(val);
        break;
      case 0x12:
        dmaLen = dmaLen.withLowByte(val);
        break;
      case 0x13:
        dmaSrcSatb = dmaSrcSatb.withLowByte(val);
        break;
    }
  }

  writeMsb(int val) {
    // print("writeMsb: ${hex8(val)}");
    switch (reg) {
      case 0x00:
        mawr = mawr.withHighByte(val);
        break;
      case 0x01:
        marr = marr.withHighByte(val);
        readLatch = vram[marr];
        break;
      case 0x02:
        writeLatch = writeLatch.withHighByte(val);
        vram[mawr] = writeLatch;
        mawr = (mawr + addrInc) & 0xffff;
        break;

      case 0x05:
        addrInc = switch (val & 0x18) {
          0x00 => 1,
          0x08 => 32,
          0x10 => 64,
          0x18 => 128,
          int() => throw UnimplementedError(),
        };
        break;

      case 0x06:
        rasterCompareRegister = rasterCompareRegister.withHighByte(val & 0x03);
        break;
      case 0x07:
        scrollX = scrollX.withHighByte(val & 0x03);
        break;
      case 0x08:
        scrollY = scrollY.withHighByte(val & 0x01);
        VdcRenderer.renderLine = scrollY;
        // print("scrollY MSB: ${hex8(val)} $scrollY");
        break;

      case 0x09:
        break;

      case 0x0f:
        break;
      case 0x10:
        dmaSrc = dmaSrc.withHighByte(val);
        break;
      case 0x11:
        dmaDst = dmaDst.withHighByte(val);
        break;
      case 0x12:
        dmaLen = dmaLen.withHighByte(val);
        dma = true;
        break;
      case 0x13:
        dmaSrcSatb = dmaSrcSatb.withHighByte(val);
        dmaSatb = true;
        break;
    }
  }

  // VCE

  final colorTable = List<int>.filled(512, 0x1ff, growable: false);
  int colorTableAddress = 0;

  int readColorTableLsb() {
    return colorTable[colorTableAddress] & 0xff;
  }

  int readColorTableMsb() {
    final value = (colorTable[colorTableAddress] >> 8) | 0xfe;
    colorTableAddress = (colorTableAddress + 1) & 0x1ff;
    return value;
  }

  writeColorTableLsb(int val) {
    colorTable[colorTableAddress] =
        colorTable[colorTableAddress].withLowByte(val);
  }

  writeColorTableMsb(int val) {
    colorTable[colorTableAddress] =
        colorTable[colorTableAddress].withHighByte(val & 1);
    colorTableAddress = (colorTableAddress + 1) & 0x1ff;
  }

  writeColorTableAddressLsb(int val) {
    colorTableAddress = colorTableAddress.withLowByte(val);
  }

  writeColorTableAddressMsb(int val) {
    colorTableAddress = colorTableAddress.withHighByte(val & 1);
  }

  // DMA

  int dmaSrc = 0;
  int dmaSrcDir = 0;
  int dmaDst = 0;
  int dmaDstDir = 0;
  int dmaLen = 0;
  bool dma = false;
  bool enableDmaVramIrq = false;
  bool enableDmaSatIrq = false;

  int dmaSrcSatb = 0;
  bool dmaSatb = false;
  bool dmaSatbAlways = false;

  execDmaSatb() {
    // print("execDmaSatb : $dmaSatb ${hex16(dmaSrcSatb)}");
    if (dmaSatb) {
      for (int i = 0; i < sat.length; i++) {
        sat[i] = vram[(dmaSrcSatb + i) & 0xffff];
      }

      if (!dmaSatbAlways) {
        dmaSatb = false;
      }

      if (enableDmaSatIrq) {
        status |= statusDmaSat;
        bus.cpu.holdInterrupt(Interrupt.irq1);
      }
    }
  }

  execDmaVram() {
    if (!dma) {
      return;
    }

    dma = false;

    for (int i = 0; i < 1024; i++) {
      vram[dmaDst] = vram[dmaSrc];
      dmaSrc = (dmaSrc + dmaSrcDir) & 0xffff;
      dmaDst = (dmaDst + dmaDstDir) & 0xffff;
      dmaLen--;

      if (dmaLen == 0) {
        if (enableDmaVramIrq) {
          status |= statusDmaVram;
          bus.cpu.holdInterrupt(Interrupt.irq1);
        }
        break;
      }
    }
  }
}
