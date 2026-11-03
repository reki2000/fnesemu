import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/sh4.dart';
import 'package:test/test.dart';

void main() {
  late DcBus bus;
  late Sh4 cpu;
  const code = 0xac010000, virtual = 0x12345000, physical = 0x0c020000;
  setUp(() {
    bus = DcBus();
    cpu = Sh4(bus)..sr = 0x40000000;
    cpu.pc = code;
    cpu.vbr = 0x8c030000;
    bus.write16(code, 0x6212); // MOV.L @R1,R2.
  });

  void entry(int index, int address, int target,
      {int flags = 0x174, int asid = 0}) {
    bus.write32(0xf6000000 + index * 256, address | asid);
    bus.write32(0xf7000000 + index * 256, target | flags);
  }

  Matcher event(int value) =>
      isA<DcCpuException>().having((e) => e.event, 'event', value);

  for (var size = 0; size < 4; size++) {
    test('page size $size preserves only the correct virtual offset bits', () {
      const masks = [0x3ff, 0xfff, 0xffff, 0xfffff];
      final mask = masks[size];
      entry(0, virtual & ~mask, physical & ~mask,
          flags: 0x164 | ((size & 1) << 4) | ((size & 2) << 6));
      bus.mmucr = 1;
      for (final offset in [0, 4, mask - 3]) {
        final mapping = bus.mmu.translate((virtual & ~mask) + offset)!;
        expect(mapping.physical, (physical & ~mask) + offset);
      }
      expect(() => bus.mmu.translate((virtual & ~mask) + mask + 1),
          throwsA(event(0x40)));
    });
  }
















  test('ITLB replacement agrees with independent least-recent-use ordering',
      () {
    for (var page = 0; page < 8; page++) {
      entry(page, virtual + page * 0x1000, physical + page * 0x1000);
    }
    bus.mmucr = 1;
    final recent = <int>[];
    for (final page in [0, 1, 2, 3, 0, 4, 1, 5, 5, 2, 6, 0, 7]) {
      recent.remove(page);
      recent.add(page);
      if (recent.length > 4) recent.removeAt(0);
      bus.mmu.translate(virtual + page * 0x1000, instruction: true);
      final resident = <int>[];
      for (var slot = 0; slot < 4; slot++) {
        final high = bus.read32(0xf2000000 + slot * 256);
        if (high & 0x100 != 0) {
          resident.add(((high & 0xfffffc00) - virtual) ~/ 0x1000);
        }
      }
      expect(resident, unorderedEquals(recent));
    }
  });

  test(
      'associative UTLB invalidation updates matching ITLB data and address views',
      () {
    entry(0, virtual, physical);
    bus.mmucr = 1;
    bus.mmu.translate(virtual, instruction: true);
    bus.write32(0xf6000080, virtual);
    expect(bus.read32(0xf6000000) & 0x300, 0);
    expect(bus.read32(0xf7000000) & 0x104, 0);
    expect(bus.read32(0xf2000300) & 0x100, 0);
    expect(bus.read32(0xf3000300) & 0x100, 0);
  });






}
