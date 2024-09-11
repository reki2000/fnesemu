// Dart imports:
import 'bus.dart';

class Vdc {
  final Bus bus;

  Vdc(this.bus) {
    bus.vdc = this;
  }

  reset() {}

  int reg = 0;

  int lsb = 0;
  int msb = 0;

  int mawr = 0;
  int marr = 0;
  int addrInc = 0;

  bool enableBg = false;
  bool enableSprite = false;
  bool enableVBlank = false;
  bool enableScanlineIrq = false;
  bool enalbeSpriteCollision = false;
  bool enableSpriteOverflow = false;

  int writeLatch = 0;

  int cr = 0;

  int vd = 0x00;
  int bsy = 0x00;
  int dv = 0x00;
  int ds = 0x00;
  int rr = 0x00;
  int or = 0x00;

  int bgWidthBits = 5;
  int bgHeightBits = 5;
  bool bgTreatPlane23Zero = false;
  int vramDotWidth = 0;

  final vram = List<int>.filled(0x10000, 0); // 2 bytes per word

  int readReg() {
    final value = vd | bsy | dv | ds | rr | or | cr;
    dv = ds = rr = or = cr = 0;
    return value;
  }

  int readLsb() {
    return lsb;
  }

  int readMsb() {
    marr = (marr + addrInc) & 0xffff;
    lsb = vram[marr] & 0xff;
    msb = vram[marr] >> 8;
    return msb;
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
      case 0x02:
        writeLatch = val;
        break;
      case 0x05:
        cr = cr & 0xff00 | val;
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
        lsb = vram[marr] & 0xff;
        msb = vram[marr] >> 8;
        break;
      case 0x02:
        vram[mawr] = val << 8 | writeLatch;
        mawr = (mawr + addrInc) & 0xffff;
        break;
      case 0x05:
        cr = val << 8 | cr & 0xff;
        enableBg = cr & 0x80 != 0;
        enableSprite = cr & 0x40 != 0;
        enableVBlank = cr & 0x08 != 0;
        enableScanlineIrq = cr & 0x040 != 0;
        enalbeSpriteCollision = cr & 0x01 != 0;
        enableSpriteOverflow = cr & 0x02 != 0;
        addrInc = switch (cr & 0x1800) {
          0x0000 => 1,
          0x0800 => 32,
          0x1000 => 64,
          0x1800 => 128,
          int() => throw UnimplementedError(),
        };
      case 0x09:
        vramDotWidth = val & 0x03;
        bgWidthBits = switch (val & 0x18) {
          0x00 => 5,
          0x08 => 6,
          0x10 => 7,
          0x18 => 7,
          int() => throw UnimplementedError(),
        };
        bgHeightBits = switch (val & 0x20) {
          0x00 => 5,
          0x20 => 6,
          int() => throw UnimplementedError(),
        };
        bgTreatPlane23Zero = val & 0x80 == 0;
        print(
            "bgTreadPlace32Zero: $bgTreatPlane23Zero, vramDotWidth:$vramDotWidth, bg: $bgWidthBits x $bgHeightBits");
        break;
    }
  }

  final colorTable = List<int>.filled(512, 0x1ff, growable: false);
  int colorTableAddress = 0;

  writeColorTableLsb(int val) {
    colorTable[colorTableAddress] =
        colorTable[colorTableAddress] & 0xff00 | val;
  }

  writeColorTableMsb(int val) {
    // print(
    //     "writeColorTableAddress: $colorTableAddress, ${colorTable[colorTableAddress] & 0xff | (val << 8)}");
    colorTable[colorTableAddress] =
        colorTable[colorTableAddress] & 0xff | (val << 8);
    colorTableAddress++;
  }

  writeColorTableAddressLsb(int val) {
    colorTableAddress = colorTableAddress & 0xff00 | val;
  }

  writeColorTableAddressMsb(int val) {
    colorTableAddress = (val << 8) | colorTableAddress & 0xff;
  }
}
