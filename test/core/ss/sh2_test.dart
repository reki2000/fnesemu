import 'dart:typed_data';

import 'package:fnesemu/core/sram.dart';
import 'package:fnesemu/core/ss/cpu.dart';
import 'package:fnesemu/core/ss/sh2/sh2.dart';
import 'package:fnesemu/core/ss/ss.dart';
import 'package:test/test.dart';

class _RamBus implements SsCpuBus {
  final mem = Uint8List(0x10000);
  late final data = ByteData.sublistView(mem);

  @override
  int read8(int a) => mem[a & 0xffff];
  @override
  int read16(int a) => data.getUint16(a & 0xfffe);
  @override
  int read32(int a) => data.getUint32(a & 0xfffc);
  @override
  void write8(int a, int d) => mem[a & 0xffff] = d & 0xff;
  @override
  void write16(int a, int d) => data.setUint16(a & 0xfffe, d & 0xffff);
  @override
  void write32(int a, int d) => data.setUint32(a & 0xfffc, d & 0xffffffff);
}

// runs a program placed at 0x1000 with the stack at 0x8000
Sh2 _run(List<int> program,
    {int steps = 1000, void Function(Sh2, _RamBus)? setup}) {
  final bus = _RamBus();
  bus.write32(0, 0x1000);
  bus.write32(4, 0x8000);
  for (int i = 0; i < program.length; i++) {
    bus.write16(0x1000 + i * 2, program[i]);
  }
  final cpu = Sh2(bus)..reset();
  setup?.call(cpu, bus);
  for (int i = 0; i < steps; i++) {
    expect(cpu.step(), true, reason: "stopped at ${cpu.pc.toRadixString(16)}");
  }
  return cpu;
}

const _loop = [0xaffe, 0x0009]; // bra $ ; nop

void main() {
  group('sh2 instructions', () {
    test('loop with dt and bf', () {
      final cpu = _run([
        0xe00a, // mov #10,r0
        0xe100, // mov #0,r1
        0x310c, // add r0,r1
        0x4010, // dt r0
        0x8bfc, // bf -4
        ..._loop,
      ]);
      expect(cpu.r[1], 55);
      expect(cpu.pc, 0x100a);
    });

    test('bsr / rts with delay slots', () {
      final cpu = _run([
        0xb006, // bsr 0x1010
        0xe201, // mov #1,r2 (slot)
        ..._loop, // 0x1004
        0x0009, 0x0009, 0x0009, 0x0009, // padding
        0x000b, // 0x1010: rts
        0xe302, // mov #2,r3 (slot)
      ], steps: 20);
      expect(cpu.r[2], 1);
      expect(cpu.r[3], 2);
      expect(cpu.pr, 0x1004);
      expect(cpu.pc, 0x1004);
    });

    test('div1 unsigned 32 / 16', () {
      final cpu = _run([
        0x4028, // shll16 r0
        0x0019, // div0u
        for (int i = 0; i < 16; i++) 0x3104, // div1 r0,r1
        0x4124, // rotcl r1
        0x611d, // extu.w r1,r1
        ..._loop,
      ], steps: 40, setup: (cpu, _) {
        cpu.r[0] = 7;
        cpu.r[1] = 1000;
      });
      expect(cpu.r[1], 142);
    });

    test('div1 unsigned 32 / 32', () {
      final cpu = _run([
        0xe200, // mov #0,r2
        0x0019, // div0u
        for (int i = 0; i < 32; i++) ...[0x4124, 0x3204], // rotcl r1; div1 r0,r2
        0x4124, // rotcl r1
        ..._loop,
      ], steps: 80, setup: (cpu, _) {
        cpu.r[0] = 37;
        cpu.r[1] = 100000;
      });
      expect(cpu.r[1], 100000 ~/ 37);
    });

    for (final (dividend, divisor) in [(-1000, 7), (1000, -7), (-1000, -7)]) {
      test('div0s / div1 signed $dividend / $divisor', () {
        // r1 (32 bit) / r0 (16 bit) = r1 (16 bit), from the SH-2 manual
        final cpu = _run([
          0x4028, // shll16 r0
          0x611f, // exts.w r1,r1
          0x222a, // xor r2,r2
          0x6313, // mov r1,r3
          0x4324, // rotcl r3
          0x312a, // subc r2,r1
          0x2107, // div0s r0,r1
          for (int i = 0; i < 16; i++) 0x3104, // div1 r0,r1
          0x611f, // exts.w r1,r1
          0x4124, // rotcl r1
          0x312e, // addc r2,r1
          0x611f, // exts.w r1,r1
          ..._loop,
        ], steps: 40, setup: (cpu, _) {
          cpu.r[0] = divisor & 0xffffffff;
          cpu.r[1] = dividend & 0xffffffff;
        });
        expect(cpu.r[1].toSigned(32), dividend ~/ divisor);
      });
    }

    test('mac.l and mac.w', () {
      final cpu = _run([
        0x0028, // clrmac
        0x054f, // mac.l @r4+,@r5+
        0x054f, // mac.l @r4+,@r5+
        0x000a, // sts mach,r0
        0x011a, // sts macl,r1
        0x0028, // clrmac
        0x476f, // mac.w @r6+,@r7+
        0x476f, // mac.w @r6+,@r7+
        0x021a, // sts macl,r2
        0x030a, // sts mach,r3
        ..._loop,
      ], steps: 20, setup: (cpu, bus) {
        bus.write32(0x2000, 2);
        bus.write32(0x2004, -3);
        bus.write32(0x2010, 4);
        bus.write32(0x2014, 5);
        bus.write16(0x2020, 3);
        bus.write16(0x2022, -2);
        bus.write16(0x2030, 7);
        bus.write16(0x2032, 7);
        cpu.r[5] = 0x2000;
        cpu.r[4] = 0x2010;
        cpu.r[7] = 0x2020;
        cpu.r[6] = 0x2030;
      });
      expect(cpu.r[0], 0xffffffff);
      expect(cpu.r[1], 0xfffffff9);
      expect(cpu.r[2], 7);
      expect(cpu.r[3], 0);
      expect(cpu.r[4], 0x2018);
      expect(cpu.r[5], 0x2008);
    });

    test('mac.w saturation', () {
      final cpu = _run([0x476f, ..._loop], steps: 1, setup: (cpu, bus) {
        cpu.sr |= 2; // S bit
        cpu.macl = 0x7ffffff0;
        cpu.r[6] = 0x2000;
        cpu.r[7] = 0x2002;
        bus.write16(0x2000, 0x100);
        bus.write16(0x2002, 0x100);
      });
      expect(cpu.macl, 0x7fffffff);
      expect(cpu.mach & 1, 1);
    });

    test('trapa and rte', () {
      final cpu = _run([
        0xc320, // trapa #0x20
        0xe701, // mov #1,r7
        ..._loop,
      ], steps: 10, setup: (cpu, bus) {
        bus.write32(0x20 * 4, 0x1100);
        bus.write16(0x1100, 0xe602); // mov #2,r6
        bus.write16(0x1102, 0x002b); // rte
        bus.write16(0x1104, 0x0009); // nop
      });
      expect(cpu.r[6], 2);
      expect(cpu.r[7], 1);
      expect(cpu.r[15], 0x8000);
    });
  });

  group('sh2 on-chip', () {
    Sh2 cpu() {
      final c = Sh2(_RamBus())..reset();
      return c;
    }

    test('DIVU 32 / 32 and 64 / 32', () {
      final c = cpu();
      c.bus.write32(0xffffff00, 7);
      c.bus.write32(0xffffff04, -100);
      expect(c.bus.read32(0xffffff04), (-14) & 0xffffffff);
      expect(c.bus.read32(0xffffff10), (-2) & 0xffffffff);
      expect(c.bus.read32(0xffffff14), (-14) & 0xffffffff);

      c.bus.write32(0xffffff00, 3);
      c.bus.write32(0xffffff10, 1);
      c.bus.write32(0xffffff14, 0);
      expect(c.bus.read32(0xffffff14), 0x100000000 ~/ 3);
      expect(c.bus.read32(0xffffff10), 1);

      // mirror at 0xffffff20
      expect(c.bus.read32(0xffffff34), 0x100000000 ~/ 3);

      c.bus.write32(0xffffff00, 0);
      c.bus.write32(0xffffff04, 5);
      expect(c.bus.read32(0xffffff08) & 1, 1); // overflow
    });

    test('DMAC auto request transfer', () {
      final c = cpu();
      for (int i = 0; i < 16; i++) {
        c.bus.write8(0x3000 + i, i + 1);
      }
      c.bus.write32(0xffffff80, 0x3000); // SAR0
      c.bus.write32(0xffffff84, 0x4000); // DAR0
      c.bus.write32(0xffffff88, 4); // TCR0
      c.bus.write32(0xffffffb0, 1); // DMAOR: DME
      c.bus.write32(0xffffff8c, 0x5a05); // inc/inc, long, auto, IE, DE
      for (int i = 0; i < 16; i++) {
        expect(c.bus.read8(0x4000 + i), i + 1);
      }
      expect(c.bus.read32(0xffffff8c) & 2, 2); // TE
      expect(c.bus.read32(0xffffff88), 0);

      // end interrupt
      c.bus.write16(0xfffffee2, 0x0a00); // IPRA: DMAC level 10
      c.bus.write32(0xffffffa0, 0x70); // VCRDMA0
      expect(c.onchip.pendingInterrupt(), (10, 0x70));
    });

    test('BCR1 tells master / slave', () {
      final master = Sh2(_RamBus(), master: true)..reset();
      final slave = Sh2(_RamBus(), master: false)..reset();
      expect(master.bus.read32(0xffffffe0) & 0x8000, 0);
      expect(slave.bus.read32(0xffffffe0) & 0x8000, 0x8000);
      expect(master.bus.read16(0xffffffe2) & 0x8000, 0);
    });

    test('cache data array as RAM and cache-through area', () {
      final c = cpu();
      c.bus.write32(0xc0000100, 0x12345678);
      expect(c.bus.read32(0xc0000100), 0x12345678);
      expect(c.bus.read16(0xc0000102), 0x5678);

      c.bus.write32(0x20002000, 0xcafebabe);
      expect(c.bus.read32(0x00002000), 0xcafebabe);

      c.bus.write32(0x40002000, 0); // purge: ignored
      expect(c.bus.read32(0x00002000), 0xcafebabe);
    });

    test('FRT compare match and input capture flags', () {
      final c = cpu();
      c.bus.write8(0xfffffe16, 0); // TCR: clock / 8
      c.bus.write8(0xfffffe14, 0x00); // OCRA H
      c.bus.write8(0xfffffe15, 0x10); // OCRA L
      c.onchip.tick(8 * 0x10);
      expect(c.bus.read8(0xfffffe11) & 0x08, 0x08); // OCFA

      c.frtInputCapture();
      expect(c.bus.read8(0xfffffe11) & 0x80, 0x80);
      expect(c.bus.read8(0xfffffe18) << 8 | c.bus.read8(0xfffffe19), 0x10);

      c.bus.write8(0xfffffe11, 0x00); // clear flags
      expect(c.bus.read8(0xfffffe11), 0);
    });
  });

  group('sh2 on ss', () {
    Ss newSs() {
      final bios = Uint8List(0x80000);
      final d = ByteData.sublistView(bios);
      d.setUint32(0, 0x06000100); // PC
      d.setUint32(4, 0x06004000); // SP
      final ss = Ss()
        ..setSram(Sram())
        ..setRom(bios);
      ss.reset();
      return ss;
    }

    void program(Ss ss, int addr, List<int> ops) {
      for (int i = 0; i < ops.length; i++) {
        ss.bus.write16(addr + i * 2, ops[i]);
      }
    }

    Sh2 master(Ss ss) => ss.master as Sh2;

    void setupHandler(Ss ss, int vector) {
      final cpu = master(ss);
      program(ss, 0x06000100, _loop);
      program(ss, 0x06001000, [0x7501, 0x002b, 0x0009]); // add #1,r5; rte; nop
      ss.bus.write32(0x06000000 + vector * 4, 0x06001000);
      cpu.vbr = 0x06000000;
      cpu.pc = 0x06000100;
      cpu.sr = 0; // interrupt mask 0
    }

    test('SCU vblank-in interrupt with external vector', () {
      final ss = newSs();
      setupHandler(ss, 0x40);
      final cpu = master(ss);

      cpu.bus.write16(0xfffffee0, 0x0001); // ICR: VECMD
      ss.bus.write32(0x25fe00a0, 0); // IMS: all enabled

      ss.scu.onVBlankIn();
      for (int i = 0; i < 20; i++) {
        ss.exec(false);
      }

      expect(cpu.r[5], 1);
      expect(ss.scu.ist & 1, 0);
      expect(cpu.pc & 0xfffffffc, 0x06000100);
      expect(cpu.sr & 0xf0, 0);
    });

    test('SINIT write raises FRT input capture interrupt on master', () {
      final ss = newSs();
      setupHandler(ss, 0x60);
      final cpu = master(ss);

      cpu.bus.write8(0xfffffe10, 0x81); // TIER: ICIE
      cpu.bus.write16(0xfffffe60, 0x0f00); // IPRB: FRT level 15
      cpu.bus.write16(0xfffffe66, 0x6000); // VCRC: ICI vector 0x60

      ss.bus.write16(0x21800000, 0); // SINIT
      for (int i = 0; i < 20; i++) {
        ss.exec(false);
      }
      expect(cpu.r[5], greaterThanOrEqualTo(1));
      expect(cpu.onchip.ftcsr & 0x80, 0x80);
    });

    test('NMI request from SMPC', () {
      final ss = newSs();
      setupHandler(ss, 11);
      final cpu = master(ss);
      cpu.sr = 0xf0;

      ss.bus.write8(0x2010001f, 0x18); // NMIREQ
      for (int i = 0; i < 400; i++) {
        ss.exec(false);
      }
      expect(cpu.r[5], 1);
    });

    test('slave runs after SSHON', () {
      final ss = newSs();
      program(ss, 0x06000100, [0x7401, ..._loop]); // add #1,r4; bra $
      ss.bus.write8(0x2010001f, 0x02); // SSHON
      for (int i = 0; i < 400; i++) {
        ss.exec(false);
      }
      expect((ss.slave as Sh2).r[4], 1);
      expect((ss.slave as Sh2).bus.read32(0xffffffe0) & 0x8000, 0x8000);
    });
  });
}
