import 'package:fnesemu/core/snes/component/bus.dart';
import 'package:fnesemu/core/snes/component/dma.dart';
import 'package:fnesemu/core/snes/component/ppu.dart';
import 'package:test/test.dart';

import 'test_rom.dart';

void main() {
  group('hdma', () {
    (Bus, Dma, Ppu) setup(List<int> table) {
      final bus = busWith(loRom());
      final ppu = Ppu();
      final dma = Dma(bus);
      bus.ppu = ppu;
      bus.dma = dma;
      bus.wram.setAll(0x1000, table);
      dma.channels[0]
        ..dmap = 0 // 1 register, write once
        ..bbad = 0x18 // VMDATAL: every write advances the vram address
        ..a1tAddr = 0x1000
        ..a1bBank = 0x7e;
      dma.hdmaEnableMask = 1;
      return (bus, dma, ppu);
    }

    test('non-repeat entry transfers only on its first line', () {
      final (_, dma, ppu) = setup([0x03, 0xaa, 0x00]);
      dma.hdmaInit();
      for (int i = 0; i < 3; i++) {
        dma.hdmaScanline();
      }
      expect(ppu.vramAddr, 1);
      expect(ppu.vram[0], 0xaa);
    });

    test('repeat entry transfers on every line', () {
      final (_, dma, ppu) = setup([0x83, 0x01, 0x02, 0x03, 0x00]);
      dma.hdmaInit();
      for (int i = 0; i < 3; i++) {
        dma.hdmaScanline();
      }
      expect(ppu.vramAddr, 3);
      expect([ppu.vram[0], ppu.vram[2], ppu.vram[4]], [1, 2, 3]);
    });
  });
}
