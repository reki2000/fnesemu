import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ss/cpu.dart';
import 'package:fnesemu_core/src/core/ss/sh2/sh2.dart';
import 'package:fnesemu_core/src/core/ss/ss.dart';
import 'package:fnesemu_core/src/sram.dart';
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

    for (final (dividend, divisor) in [(-1000, 7), (1000, -7), (-1000, -7)]) {
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

  });

  group('sh2 on-chip', () {
    Sh2 cpu() {
      final c = Sh2(_RamBus())..reset();
      return c;
    }

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
      addTearDown(ss.dispose);
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
