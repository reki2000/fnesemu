import 'package:fnesemu/core/gba/bus.dart';
import 'package:fnesemu/util/int.dart';
import 'package:test/test.dart';

void main() {
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
}
