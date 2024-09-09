// Dart imports:
import 'package:fnesemu/core/component/vdc_render.dart';

import 'bus.dart';

class Vdc2 extends Vdc with VdcRenderer {
  Vdc2(super.bus);
}

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
    }
  }
}
