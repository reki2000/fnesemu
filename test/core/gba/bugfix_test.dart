import 'dart:typed_data';

import 'package:fnesemu/core/gba/arm7tdmi/arm7.dart';
import 'package:fnesemu/core/gba/arm7tdmi/regs.dart';
import 'package:fnesemu/core/gba/bus.dart';
import 'package:fnesemu/core/gba/gba.dart';
import 'package:fnesemu/core/gba/irq.dart';
import 'package:fnesemu/core/gba/ppu.dart';
import 'package:fnesemu/util/int.dart';
import 'package:test/test.dart';

import 'arm7_asm.dart';

Uint8List _words(List<int> words) {
  final b = Uint8List(words.length * 4);
  for (var i = 0; i < words.length; i++) {
    final w = words[i];
    b[i * 4] = w.mask8;
    b[i * 4 + 1] = w.shr8.mask8;
    b[i * 4 + 2] = w.shr16.mask8;
    b[i * 4 + 3] = w.shr24.mask8;
  }
  return b;
}

void main() {
  test('ldm {..,pc}^ writes the base back in the exception mode bank', () {
    final bus = Bus();
    // 0x08000000: ldmia sp!, {r0, pc}^ ; 0x08000010: b .
    bus.cart.load(_words([
      aLdm(13, 0x8001, wb: true) | (1 << 22),
      aNop,
      aNop,
      aNop,
      aBSelf,
    ]));
    final cpu = Arm7(bus)..resetHle();
    final regs = cpu.regs;

    regs.switchMode(CpuMode.irq);
    regs.spsr = CpuMode.sys;
    regs.r[13] = 0x03000000;
    bus.write32(0x03000000, 0x1234);
    bus.write32(0x03000004, 0x08000010);

    cpu.step();

    expect(regs.mode, CpuMode.sys);
    expect(regs.r[0], 0x1234);
    expect(regs.r[13], 0x03007f00); // sys sp untouched
    regs.switchMode(CpuMode.irq);
    expect(regs.r[13], 0x03000008); // irq sp written back
  });

  test('byte write to IF only acknowledges that byte', () {
    final bus = Bus();
    bus.irq.raise(IrqBit.vblank);
    bus.irq.raise(IrqBit.dma0);
    bus.write8(0x04000202, 0x01);
    expect(bus.irq.if_, 1 << IrqBit.dma0);
  });

  test('byte writes to write-only DMA registers are merged', () {
    final bus = Bus();
    bus.write32(0x02000000, 0xcafebabe);
    bus.write32(0x02000004, 0x11111111);
    void w32(int addr, int v) {
      for (int i = 0; i < 4; i++) {
        bus.write8(addr + i, v.shr(i * 8).mask8);
      }
    }

    w32(0x040000d4, 0x02000000); // DMA3 SAD
    w32(0x040000d8, 0x02000100); // DMA3 DAD
    bus.write8(0x040000dc, 1); // DMA3 CNT_L = 1
    bus.write8(0x040000dd, 0);
    bus.write8(0x040000de, 0x00); // CNT_H low: 16-bit, increment
    bus.write8(0x040000df, 0x84); // CNT_H high: enable, 32-bit, immediate

    expect(bus.read32(0x02000100), 0xcafebabe);
    expect(bus.read32(0x02000104), 0); // exactly one word (CNT_L kept)
  });

  test('PSG frequency byte writes keep the other byte', () {
    final bus = Bus();
    bus.write16(0x04000084, 0x0080); // master enable
    bus.write16(0x04000062, 0xf080); // duty 50%, volume 15
    bus.write8(0x04000064, 0x34);
    bus.write8(0x04000065, 0x87); // trigger, freq 0x734
    expect(bus.read16(0x04000084).mask1, 1);
    // re-writing the low byte must not lose the high bits
    bus.write8(0x04000064, 0x35);
    expect(bus.io[0x64] | bus.io[0x65].shl8, 0x0735);
  });

  test('DISPSTAT HBlank flag can be polled during the line', () {
    final gba = Gba()..setRom(_words([aBSelf]));
    var sawHblank = false;
    while (gba.bus.vcount == 0) {
      gba.exec(false);
      if (gba.bus.read16(0x04000004).bit1) {
        sawHblank = true;
        expect(gba.bus.vcount, 0);
      }
    }
    expect(sawHblank, isTrue);
    expect(gba.bus.read16(0x04000004) & 2, 0);
  });

  group('Ppu', () {
    test('8bpp BG tiles beyond BG VRAM do not crash', () {
      final bus = Bus();
      final ppu = Ppu(bus);
      bus.write16(0x04000000, 0x0100); // mode 0, BG0
      bus.write16(0x04000008, 0x008c); // char base 3, 8bpp, screen base 0
      for (int i = 0; i < 0x800; i += 2) {
        bus.write16(0x06000000 + i, 0x03ff); // tile 1023
      }
      expect(() => ppu.renderLine(0), returnsNormally);
    });

    test('OBJ tile numbers wrap within OBJ VRAM', () {
      final bus = Bus();
      final ppu = Ppu(bus);
      bus.write16(0x04000000, 0x1040); // OBJ on, 1D mapping
      bus.write16(0x07000000, 0x2000); // y=0, 256 colours, square
      bus.write16(0x07000002, 0xc000); // x=0, 64x64
      bus.write16(0x07000004, 0x03f0); // tile 1008
      for (int y = 0; y < 64; y++) {
        expect(() => ppu.renderLine(y), returnsNormally);
      }
    });

    test('OBJ disabled hides sprites even with the OBJ window on', () {
      final bus = Bus();
      final ppu = Ppu(bus);
      bus.write16(0x04000000, 0x8040); // OBJ window on, OBJ off
      bus.write16(0x0400004a, 0x003f); // WINOUT: everything visible
      bus.write16(0x05000202, 0x001f); // OBJ palette 1 = red
      bus.write16(0x06010000, 0x1111); // tile 0: colour 1
      bus.write16(0x07000000, 0x0000);
      bus.write16(0x07000002, 0x0000);
      bus.write16(0x07000004, 0x0000);
      ppu.renderLine(0);
      expect(ppu.buffer[0], isNot(0xff0000ff));
    });

    test('mid-frame BG2Y write reloads the affine reference point', () {
      final bus = Bus();
      final ppu = Ppu(bus);
      bus.write16(0x04000000, 0x0403); // mode 3, BG2
      bus.write16(0x04000020, 0x0100);
      bus.write16(0x04000026, 0x0100);
      bus.write16(0x06000000, 0x001f); // (0,0) red

      for (int y = 0; y < 10; y++) {
        ppu.renderLine(y);
      }
      bus.write32(0x0400002c, 0); // BG2Y = 0 -> line 10 shows row 0
      ppu.renderLine(10);
      expect(ppu.buffer[10 * 240], 0xff0000ff);
    });
  });
}
