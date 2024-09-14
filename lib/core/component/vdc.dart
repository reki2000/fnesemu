// Dart imports:
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
    return "vdc: $scr $flags";
  }

  reset() {
    for (int i = 0; i < vram.length; i++) {
      vram[i] = 0;
    }
  }

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
  static const bsy = 0x40;
  static const vd = 0x20;
  static const dv = 0x10;
  static const ds = 0x08;
  static const rr = 0x04;
  static const or = 0x02;
  static const cr = 0x01;

  int rasterCompareRegister = 0;

  int controlRegister = 0;

  int bgWidthBits = 5;
  int bgHeightBits = 5;

  int bgWidthMask = 0x1f;
  int bgHeightMask = 0x1f;

  bool bgTreatPlane23Zero = false;
  int vramDotWidth = 0;

  final vram = List<int>.filled(0x10000, 0); // 2 bytes per word

  int readReg() {
    bus.acknoledgeIrq1();

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
    reg = val & 0x0f;
  }

  writeLsb(int val) {
    // print("writeLsb: ${hex8(val)}");
    switch (reg) {
      case 0x00:
        mawr = mawr & 0xff00 | val;
        break;
      case 0x01:
        marr = marr & 0xff00 | val;
        break;
      case 0x02:
        writeLatch = val;
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
        rasterCompareRegister = rasterCompareRegister & 0xff00 | val;
        break;
      case 0x07:
        scrollX = scrollX & 0xff00 | val;
        break;
      case 0x08:
        scrollY = val;
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
        print(
            "bgTreatPlane23Zero: $bgTreatPlane23Zero, vramDotWidth:$vramDotWidth, bg: ${bgWidthMask + 1} x ${bgHeightMask + 1}");
        break;

      case 0x0f:
        enableDmaCgIrq = val & 0x01 != 0;
        enableDmaVramIrq = val & 0x02 != 0;
        dmaSrcDir = val & 0x04 != 0 ? -1 : 1;
        dmaDstDir = val & 0x08 != 0 ? -1 : 1;
        dmaSatbAlways = val & 0x10 != 0;
        break;

      case 0x10:
        dmaSrc = dmaSrc & 0xff00 | val;
        break;
      case 0x11:
        dmaDst = dmaDst & 0xff00 | val;
        break;
      case 0x12:
        dmaLen = dmaLen & 0xff00 | val;
        break;
      case 0x13:
        dmaSrcSatb = dmaSrcSatb & 0xff00 | val;
        break;
    }
  }

  writeMsb(int val) {
    // print("writeMsb: ${hex8(val)}");
    switch (reg) {
      case 0x00:
        mawr = val << 8 | mawr & 0xff;
        break;
      case 0x01:
        marr = val << 8 | marr & 0xff;
        readLatch = vram[marr];
        break;
      case 0x02:
        vram[mawr] = val << 8 | writeLatch;
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
        rasterCompareRegister = val << 8 | rasterCompareRegister & 0xff;
        break;
      case 0x07:
        scrollX = scrollX & 0xff | (val << 8);
        break;
      case 0x08:
        break;

      case 0x09:
        break;

      case 0x10:
        dmaSrc = dmaSrc & 0xff | (val << 8);
        break;
      case 0x11:
        dmaDst = dmaDst & 0xff | (val << 8);
        break;
      case 0x12:
        dmaLen = dmaLen & 0xff | (val << 8);
        break;
      case 0x13:
        dmaSrcSatb = dmaSrcSatb & 0xff | (val << 8);
        dmaSatb = true;
        break;
    }
  }

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
        colorTable[colorTableAddress] & 0x0100 | val;
  }

  writeColorTableMsb(int val) {
    // print(
    //     "writeColorTableAddress: $colorTableAddress, ${colorTable[colorTableAddress] & 0xff | (val << 8)}");
    colorTable[colorTableAddress] =
        ((val & 0x01) << 8) | colorTable[colorTableAddress] & 0xff;
    colorTableAddress = (colorTableAddress + 1) & 0x1ff;
  }

  writeColorTableAddressLsb(int val) {
    colorTableAddress = colorTableAddress & 0x0100 | val;
  }

  writeColorTableAddressMsb(int val) {
    colorTableAddress = ((val & 0x01) << 8) | colorTableAddress & 0xff;
  }

  int dmaSrc = 0;
  int dmaSrcDir = 0;
  int dmaDst = 0;
  int dmaDstDir = 0;
  int dmaLen = 0;
  bool enableDmaVramIrq = false;
  bool enableDmaCgIrq = false;

  int dmaSrcSatb = 0;
  bool dmaSatb = false;
  bool dmaSatbAlways = false;

  execDmaSatb() {
    if (dmaSatb) {
      if (!dmaSatbAlways) {
        dmaSatb = false;
      }
    }

    //
    if (enableDmaCgIrq) {
      status |= ds;
      bus.cpu.holdInterrupt(Interrupt.irq1);
    }
  }

  execDmaVram() {
    if (dmaLen == 0) {
      return;
    }

    for (int i = 0; i < 1024; i++) {
      vram[dmaDst] = vram[dmaSrc];
      dmaSrc = (dmaSrc + dmaSrcDir) & 0xffff;
      dmaDst = (dmaDst + dmaDstDir) & 0xffff;
      dmaLen--;

      if (dmaLen == 0) {
        if (enableDmaVramIrq) {
          status |= dv;
          bus.cpu.holdInterrupt(Interrupt.irq1);
        }
        break;
      }
    }

    dmaLen = 0;
  }

  int dmaCgLen = 0;
}
