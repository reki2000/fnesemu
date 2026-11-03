import 'dart:typed_data';

import 'package:fnesemu_core/src/core/gba/arm7tdmi/arm7.dart';
import 'package:fnesemu_core/src/core/gba/arm7tdmi/regs.dart';
import 'package:fnesemu_core/src/core/gba/bus.dart';
import 'package:fnesemu_core/src/util/int.dart';
import 'package:test/test.dart';

import 'support/arm7_asm.dart';

/// test bed: places [words] at the cartridge ROM base (0x08000000), boots the
/// CPU with the HLE reset (SYS mode, pc = 0x08000000) and steps it.
class ArmBed {
  final bus = Bus();
  late final Arm7 cpu;

  ArmBed(List<int> words) {
    final rom = Uint8List(words.length * 4);
    for (var i = 0; i < words.length; i++) {
      final w = words[i];
      rom[i * 4] = w.mask8;
      rom[i * 4 + 1] = w.shr8.mask8;
      rom[i * 4 + 2] = w.shr16.mask8;
      rom[i * 4 + 3] = w.shr24.mask8;
    }
    bus.cart.load(rom);
    cpu = Arm7(bus);
    cpu.resetHle();
  }

  Regs get regs => cpu.regs;
  List<int> get r => cpu.regs.r;

  void stepN(int n) {
    for (var i = 0; i < n; i++) {
      cpu.step();
    }
  }

  /// step until pc stops moving (the trailing `b .` executes twice).
  void run({int maxSteps = 10000}) {
    var last = -1;
    for (var i = 0; i < maxSteps; i++) {
      cpu.step();
      if (regs.pc == last) return;
      last = regs.pc;
    }
    throw StateError('program did not reach the end loop (pc=${regs.pc})');
  }
}

/// assemble ARM [ops], append `b .` and run to completion.
ArmBed armRun(List<int> ops) => ArmBed([...ops, aBSelf])..run();

/// run Thumb [halfwords] at 0x08000040 via an ARM `bx` stub, ending with `b .`.
ArmBed thumbRun(List<int> halfwords) {
  const thumbWordIndex = 16; // thumb code at 0x08000040
  final stub = [...aMovI32(0, 0x08000000 + thumbWordIndex * 4 + 1), aBx(0)];
  final words = [
    ...stub,
    ...List.filled(thumbWordIndex - stub.length, aNop),
  ];
  final hws = [...halfwords, tBSelf];
  if (hws.length.isOdd) hws.add(tNop);
  for (var i = 0; i < hws.length; i += 2) {
    words.add(hws[i] | hws[i + 1].shl16);
  }
  return ArmBed(words)..run();
}

void main() {
  group('ARM data processing', () {

    test('adds sets N/V on signed overflow', () {
      final t = armRun([
        aMvnI(0, 2, rot4: 1), // mvn r0, #0x80000000 -> 0x7fffffff
        aAddI(0, 0, 1, s: true),
      ]);
      expect(t.r[0], 0x80000000);
      expect(t.regs.nf, true);
      expect(t.regs.zf, false);
      expect(t.regs.cf, false);
      expect(t.regs.vf, true);
    });

  });

  group('ARM multiply', () {

    test('umull full 64-bit product', () {
      final t = armRun([aMvnI(1, 0), aMvnI(2, 0), aUmull(4, 5, 1, 2)]);
      expect(t.r[4], 1); // 0xffffffff * 0xffffffff = 0xfffffffe_00000001
      expect(t.r[5], 0xfffffffe);
    });

  });

  group('ARM memory', () {
    const base = 0x02000000; // EWRAM

    test('str/ldr word and byte lanes', () {
      final t = armRun([
        aMovI(0, 2, rot4: 4), // r0 = 0x02000000
        ...aMovI32(1, 0x11223344),
        aStr(1, 0, 0x10),
        aLdr(2, 0, 0x10),
        aLdrb(3, 0, 0x11), // little-endian byte 1
      ]);
      expect(t.bus.read32(base + 0x10), 0x11223344);
      expect(t.r[2], 0x11223344);
      expect(t.r[3], 0x33);
    });

  });

  group('ARM branch / system', () {

    test('arm->thumb->arm roundtrip via bx lr', () {
      final t = armRun([
        aMovR(1, 15), // r1 = base+8 (addr of word 2)
        aAddI(1, 1, 13), // -> thumb code at word 5, +1 for thumb bit
        aMovR(14, 15), // lr = addr of word 4
        aBx(1),
        aB(1), // return lands here; jump over the thumb words
        0x2007 | tLslsI(0, 0, 2).shl16, // movs r0,#7; lsls r0,r0,#2
        tBxLr | tNop.shl16,
        aMovI(2, 1),
      ]);
      expect(t.r[0], 28);
      expect(t.r[2], 1);
      expect(t.regs.thumb, false);
    });

  });

  group('Thumb', () {

    test('push/pop preserve sp', () {
      final t = thumbRun([
        tMovsI(0, 0x12),
        tPush(0x01), // push {r0}
        tMovsI(0, 0),
        tPop(0x02), // pop {r1}
      ]);
      expect(t.r[1], 0x12);
      expect(t.r[13], 0x03007f00); // sp restored (sys stack from HLE boot)
    });

  });

  test('ldm {..,pc}^ writes the base back in the exception mode bank', () {
    final bus = Bus();
    // 0x08000000: ldmia sp!, {r0, pc}^ ; 0x08000010: b .
    bus.cart.load(wordBytes([
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
}
