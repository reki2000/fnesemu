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

  test('ASID, SH and SV change comparison without changing page protection',
      () {
    entry(0, virtual, physical, asid: 7);
    bus.pteh = 8;
    bus.mmucr = 1;
    expect(() => bus.mmu.translate(virtual), throwsA(event(0x40)));
    bus.mmucr = 0x101;
    expect(bus.mmu.translate(virtual)!.physical, physical);
    expect(() => bus.mmu.translate(virtual, privileged: false),
        throwsA(event(0x40)));
    entry(0, virtual, physical, flags: 0x176, asid: 7);
    expect(bus.mmu.translate(virtual, privileged: false)!.physical, physical);
  });

  for (var protection = 0; protection < 4; protection++) {
    for (final privileged in [false, true]) {
      for (final write in [false, true]) {
        test('PR=$protection privileged=$privileged write=$write', () {
          entry(0, virtual, physical, flags: 0x114 | (protection << 5));
          bus.mmucr = 1;
          final permitted =
              (privileged || protection >= 2) && (!write || protection.isOdd);
          if (permitted) {
            expect(
                bus.mmu
                    .translate(virtual, privileged: privileged, write: write)!
                    .physical,
                physical);
          } else {
            expect(
                () => bus.mmu
                    .translate(virtual, privileged: privileged, write: write),
                throwsA(event(write ? 0xc0 : 0xa0)));
          }
        });
      }
    }
  }

  test('initial-page-write fault follows permission checking and never sets D',
      () {
    entry(0, virtual, physical, flags: 0x170);
    bus.mmucr = 1;
    expect(() => bus.mmu.translate(virtual, write: true), throwsA(event(0x80)));
    expect(bus.read32(0xf7000000) & 4, 0);
    entry(0, virtual, physical, flags: 0x150);
    expect(() => bus.mmu.translate(virtual, write: true), throwsA(event(0xc0)));
  });

  test(
      'LDTLB uses URC without incrementing it and copies assistance attributes',
      () {
    bus.write16(code, 0x0038);
    bus.write32(0xff000000, virtual | 7);
    bus.write32(0xff000004, physical | 0x17c);
    bus.write32(0xff000034, 15);
    bus.write32(0xff000010, 5 << 10);
    cpu.step();
    expect(bus.read32(0xf6000500), virtual | 0x307);
    expect(bus.read32(0xf7000500), physical | 0x17c);
    expect(bus.read32(0xf7800500), 15);
    expect((bus.mmucr >> 10) & 63, 5);
  });

  test('UTLB access advances URC with boundary and natural wrap', () {
    entry(0, virtual, physical);
    bus.mmucr = 1 | (3 << 18) | (2 << 10);
    bus.mmu.translate(virtual);
    expect((bus.mmucr >> 10) & 63, 0);
    bus.mmucr = 1 | (3 << 18) | (63 << 10);
    bus.mmu.translate(virtual);
    expect((bus.mmucr >> 10) & 63, 0);
  });

  test(
      'ITLB refills from UTLB, remains stale after UTLB replacement, and TI invalidates',
      () {
    entry(0, virtual, physical);
    bus.mmucr = 1;
    expect(bus.mmu.translate(virtual, instruction: true)!.physical, physical);
    expect(bus.read32(0xf2000300), virtual | 0x100);
    final afterFill = bus.mmucr;
    entry(0, virtual, physical + 0x1000);
    expect(bus.mmu.translate(virtual, instruction: true)!.physical, physical);
    expect(bus.mmucr, afterFill);
    bus.mmucr = bus.mmucr | 4;
    expect(bus.read32(0xf2000300) & 0x100, 0);
    expect(() => bus.mmu.translate(virtual), throwsA(event(0x40)));
  });

  test('CPU data TLB miss saves the virtual address and enters VBR+400', () {
    bus.mmucr = 1;
    bus.pteh = 7;
    cpu.r[1] = virtual;
    cpu.r[2] = 42;
    cpu.step();
    expect(bus.expevt, 0x40);
    expect(bus.tea, virtual);
    expect(bus.pteh, virtual | 7);
    expect(cpu.spc, code);
    expect(cpu.pc, 0x8c030400);
    expect(cpu.bank[2], 42);
  });

  test('CPU translates load, store and instruction fetch through physical RAM',
      () {
    entry(0, virtual, physical);
    bus.write32(physical, 42);
    bus.mmucr = 1;
    cpu.r[1] = virtual;
    cpu.step();
    expect(cpu.r[2], 42);
    bus.write16(code + 2, 0x2122);
    cpu.r[2] = 43;
    cpu.step();
    expect(bus.read32(physical), 43);
    bus.write16(physical, 0xe92a);
    cpu.pc = virtual;
    cpu.step();
    expect(cpu.r[9], 42);
    expect(cpu.pc, virtual + 2);
  });

  test(
      'mapped cache lines use virtual indexes, physical tags and C/WT attributes',
      () {
    entry(0, virtual, physical, flags: 0x17c);
    bus.write32(physical, 42);
    bus.write32(0xff00001c, 1);
    bus.mmucr = 1;
    bus.cpuWrite(virtual, 4, 43);
    expect(bus.read32(0xac020000), 42);
    expect(bus.cpuRead(virtual, 4), 43);
    expect(bus.read32(0xf4001000), physical | 3);
    bus.cpuCacheOperation(virtual, 1);
    expect(bus.read32(0xac020000), 43);
    entry(0, virtual, physical, flags: 0x17d);
    bus.cpuWrite(virtual, 4, 44);
    expect(bus.read32(0xac020000), 44);
    expect(bus.read32(0xf4001000) & 1, 0);
  });

  test('multiple data hits reset the CPU with EXPEVT 140 and virtual TEA', () {
    entry(0, virtual, physical);
    entry(1, virtual, physical + 0x1000);
    bus.mmucr = 1;
    cpu.r[1] = virtual;
    cpu.step();
    expect(bus.expevt, 0x140);
    expect(bus.tea, virtual);
    expect(cpu.pc, 0xa0000000);
    expect(bus.mmucr, 0);
    expect(bus.read32(0xf7000000) & 0x100, 0x100);
  });

  test(
      'SQ translation validates stores and chooses PREF destination independently of QACR',
      () {
    entry(0, 0xe0000000, physical);
    bus.write32(0xff000038, 0x1c);
    bus.mmucr = 1;
    bus.cpuWrite(0xe0000000, 4, 42);
    bus.transferStoreQueue(0xe0000000);
    expect(bus.read32(physical), 42);
  });

  test(
      'guest miss handler installs a page with LDTLB and resumes the faulting load',
      () {
    bus.write32(physical, 42);
    bus.mmucr = 1;
    cpu.r[1] = virtual;
    cpu.r[10] = physical | 0x174;
    cpu.r[11] = 0xff000004;
    const handler = 0x8c030400;
    for (final (offset, op) in [
      (0, 0x2ba2),
      (2, 0x0038),
      (4, 0x0009),
      (6, 0x002b),
      (8, 0x0009)
    ]) {
      bus.write16(handler + offset, op);
    }
    cpu.step();
    expect(cpu.pc, handler);
    for (var i = 0; i < 5; i++) {
      cpu.step();
    }
    expect(cpu.pc, code);
    cpu.step();
    expect(cpu.r[2], 42);
    expect(cpu.pc, code + 2);
  });

  test('instruction miss and protection fault use the appropriate vectors', () {
    bus.mmucr = 1;
    cpu.pc = virtual;
    cpu.step();
    expect(bus.expevt, 0x40);
    expect(cpu.spc, virtual);
    expect(cpu.pc, 0x8c030400);
    entry(0, virtual, physical, flags: 0x134);
    cpu.sr = 0;
    cpu.pc = virtual;
    cpu.step();
    expect(bus.expevt, 0xa0);
    expect(cpu.pc, 0x8c030100);
    expect(cpu.ssr, 0);
  });

  test(
      'initial write fault preserves a predecrement pointer and external memory',
      () {
    entry(0, virtual, physical, flags: 0x170);
    bus.mmucr = 1;
    bus.write16(code, 0x2126);
    cpu.r[1] = virtual + 4;
    cpu.r[2] = 42;
    cpu.step();
    expect(bus.expevt, 0x80);
    expect(cpu.bank[1], virtual + 4);
    expect(bus.read32(physical), 0);
  });

  test('a data miss in a call slot records the branch PC and restores PR', () {
    bus.mmucr = 1;
    bus.write16(code, 0xb000);
    bus.write16(code + 2, 0x6212);
    cpu.r[1] = virtual;
    cpu.pr = 42;
    cpu.step();
    cpu.step();
    expect(bus.expevt, 0x40);
    expect(cpu.spc, code);
    expect(cpu.pr, 42);
    expect(cpu.pc, 0x8c030400);
  });

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

  test('debug translation does not refill ITLB, advance URC, or alter LRUI',
      () {
    entry(0, virtual, physical);
    bus.write16(physical, 0xe92a);
    bus.mmucr = 1;
    expect(bus.peekInstruction16(virtual), 0xe92a);
    expect(bus.mmucr, 1);
    expect(bus.read32(0xf2000300) & 0x100, 0);
  });

  test('user mapped area-7 access decodes on-chip registers through the page',
      () {
    entry(0, 0x00100000, 0x0c010000);
    entry(1, 0x1c100000, 0x1fd00000);
    bus.write16(code, 0x6211);
    bus.write16(0xffd00004, 0x1234);
    bus.mmucr = 1;
    cpu.sr = 0;
    cpu.pc = 0x00100000;
    cpu.r[1] = 0x1c100004;
    cpu.step();
    expect(cpu.r[2], 0x1234);
    expect(cpu.pc, 0x00100002);
  });

  test('translated associative cache writes compare physical tags', () {
    entry(0, virtual, physical, flags: 0x17c);
    bus.write32(0xff00001c, 1);
    bus.mmucr = 1;
    bus.cpuWrite(virtual, 4, 42);
    bus.write32(0xf4001008, virtual); // Purge the matching physical line.
    expect(bus.read32(0xac020000), 42);
    expect(bus.read32(0xf4001000) & 1, 0);
  });

  test('manual reset retains TLB validity while full reset invalidates it', () {
    entry(0, virtual, physical);
    bus.mmucr = 1;
    bus.mmu.translate(virtual, instruction: true);
    cpu.reset(manual: true);
    expect(bus.mmucr, 0);
    expect(bus.read32(0xf7000000) & 0x100, 0x100);
    expect(bus.read32(0xf2000300) & 0x100, 0x100);
    cpu.reset();
    expect(bus.read32(0xf7000000) & 0x100, 0);
    expect(bus.read32(0xf2000300) & 0x100, 0);
  });

  test('SQ PREF uses read protection and can transfer a page with D clear', () {
    bus.write32(0xe0000000, 42);
    entry(0, 0xe0000000, physical, flags: 0x170);
    bus.mmucr = 1;
    expect(() => bus.cpuWrite(0xe0000000, 4, 43), throwsA(event(0x80)));
    bus.transferStoreQueue(0xe0000000);
    expect(bus.read32(physical), 42);
  });

  test('multiple instruction hits request a reset before fetching memory', () {
    for (var slot = 0; slot < 2; slot++) {
      bus.write32(0xf2000000 + slot * 256, virtual | 0x100);
      bus.write32(0xf3000000 + slot * 256, physical | 0x150);
    }
    bus.mmucr = 1;
    cpu.pc = virtual;
    cpu.step();
    expect(bus.expevt, 0x140);
    expect(cpu.pc, 0xa0000000);
    expect(bus.tea, virtual);
  });
}
