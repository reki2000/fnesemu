import 'dart:typed_data';

import 'package:fnesemu/core/gba/arm7tdmi/arm7.dart';
import 'package:fnesemu/core/gba/arm7tdmi/regs.dart';
import 'package:fnesemu/core/gba/bus.dart';
import 'package:test/test.dart';

import 'arm7_asm.dart';

/// test bed: places [words] at the cartridge ROM base (0x08000000), boots the
/// CPU with the HLE reset (SYS mode, pc = 0x08000000) and steps it.
class ArmBed {
  final bus = Bus();
  late final Arm7 cpu;

  ArmBed(List<int> words) {
    final rom = Uint8List(words.length * 4);
    for (var i = 0; i < words.length; i++) {
      final w = words[i];
      rom[i * 4] = w & 0xff;
      rom[i * 4 + 1] = (w >> 8) & 0xff;
      rom[i * 4 + 2] = (w >> 16) & 0xff;
      rom[i * 4 + 3] = (w >> 24) & 0xff;
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
    words.add(hws[i] | (hws[i + 1] << 16));
  }
  return ArmBed(words)..run();
}

void main() {
  group('ARM data processing', () {
    test('mov immediate with rotate', () {
      final t = armRun([
        aMovI(0, 0x12),
        aMovI(1, 0xff, rot4: 4), // 0xff ror 8 = 0xff000000
      ]);
      expect(t.r[0], 0x12);
      expect(t.r[1], 0xff000000);
    });

    test('mov+orr composes arbitrary 32-bit constants', () {
      final t = armRun([
        ...aMovI32(0, 0x12345678),
        ...aMovI32(1, 0xdeadbeef),
      ]);
      expect(t.r[0], 0x12345678);
      expect(t.r[1], 0xdeadbeef);
    });

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

    test('adds sets Z/C on unsigned wrap', () {
      final t = armRun([
        aMvnI(0, 0), // 0xffffffff
        aAddI(0, 0, 1, s: true),
      ]);
      expect(t.r[0], 0);
      expect(t.regs.nf, false);
      expect(t.regs.zf, true);
      expect(t.regs.cf, true);
      expect(t.regs.vf, false);
    });

    test('subs borrow clears C', () {
      final t = armRun([
        aMovI(0, 3),
        aSubI(0, 0, 5, s: true),
      ]);
      expect(t.r[0], 0xfffffffe);
      expect(t.regs.nf, true);
      expect(t.regs.cf, false); // C = NOT borrow
      expect(t.regs.vf, false);
    });

    test('subs equal sets Z and C', () {
      final t = armRun([
        aMovI(0, 5),
        aSubI(0, 0, 5, s: true),
      ]);
      expect(t.r[0], 0);
      expect(t.regs.zf, true);
      expect(t.regs.cf, true);
    });

    test('lsl #31 shifter carry', () {
      final t = armRun([
        aMovI(0, 1),
        aMovR(1, 0, shImm: 31, s: true),
      ]);
      expect(t.r[1], 0x80000000);
      expect(t.regs.cf, false); // carry out = bit1 of 1 = 0
      expect(t.regs.nf, true);
    });

    test('lsl #1 shifter carry from bit31', () {
      final t = armRun([
        ...aMovI32(0, 0x80000001),
        aMovR(1, 0, shImm: 1, s: true),
      ]);
      expect(t.r[1], 2);
      expect(t.regs.cf, true);
    });

    test('lsr #32 (encoded as 0)', () {
      final t = armRun([
        aMovI(0, 2, rot4: 1), // 0x80000000
        aMovR(1, 0, shType: shLsr, shImm: 0, s: true),
      ]);
      expect(t.r[1], 0);
      expect(t.regs.zf, true);
      expect(t.regs.cf, true); // carry = bit31
    });

    test('asr #32 (encoded as 0)', () {
      final t = armRun([
        aMovI(0, 2, rot4: 1), // 0x80000000
        aMovR(1, 0, shType: shAsr, shImm: 0, s: true),
      ]);
      expect(t.r[1], 0xffffffff);
      expect(t.regs.nf, true);
      expect(t.regs.cf, true);
    });

    test('rrx (ror #0) shifts carry in', () {
      final t = armRun([
        aMovI(0, 2),
        aCmpR(0, 0), // sets C=1
        aMovR(1, 0, shType: shRor, shImm: 0, s: true),
      ]);
      expect(t.r[1], 0x80000001);
      expect(t.regs.cf, false); // carry out = bit0 of 2
      expect(t.regs.nf, true);
    });

    test('shift by register', () {
      final t = armRun([
        aMovI(0, 1),
        aMovI(1, 4),
        aMovRS(2, 0, 1),
      ]);
      expect(t.r[2], 16);
    });

    test('shift by register == 32', () {
      final t = armRun([
        aMovI(0, 1),
        aMovI(1, 32),
        aMovRS(2, 0, 1, s: true),
      ]);
      expect(t.r[2], 0);
      expect(t.regs.zf, true);
      expect(t.regs.cf, true); // LSL #32: carry = bit0
    });

    test('adc adds carry in', () {
      final t = armRun([
        aCmpR(0, 0), // C=1
        aMovI(0, 1),
        aAdcI(0, 0, 2),
      ]);
      expect(t.r[0], 4);
    });

    test('sbc subtracts borrow', () {
      // C=1 (no borrow): 5 - 1 = 4
      final t1 = armRun([
        aCmpR(0, 0),
        aMovI(0, 5),
        aSbcI(0, 0, 1),
      ]);
      expect(t1.r[0], 4);
      // C=0 (borrow): 5 - 1 - 1 = 3
      final t2 = armRun([
        aMovI(1, 0),
        aAddI(1, 1, 0, s: true), // adds 0+0 clears C
        aMovI(0, 5),
        aSbcI(0, 0, 1),
      ]);
      expect(t2.r[0], 3);
    });

    test('conditional execution', () {
      final t = armRun([
        aMovI(0, 0, s: true), // Z=1
        aMovI(1, 1, cond: condEq),
        aMovI(2, 2, cond: condNe),
      ]);
      expect(t.r[1], 1);
      expect(t.r[2], 0);
    });

    test('r15 reads instruction address + 8', () {
      final t = armRun([
        aMovR(0, 15), // at 0x08000000
        aMovR(1, 15),
        aSubR(2, 1, 0),
      ]);
      expect(t.r[0], 0x08000008);
      expect(t.r[2], 4);
    });
  });

  group('ARM multiply', () {
    test('mul', () {
      final t = armRun([aMovI(1, 7), aMovI(2, 6), aMul(0, 1, 2)]);
      expect(t.r[0], 42);
    });

    test('mla', () {
      final t = armRun(
          [aMovI(1, 7), aMovI(2, 6), aMovI(3, 5), aMla(0, 1, 2, 3)]);
      expect(t.r[0], 47);
    });

    test('umull', () {
      final t = armRun([aMvnI(1, 0), aMovI(2, 2), aUmull(4, 5, 1, 2)]);
      expect(t.r[4], 0xfffffffe); // lo
      expect(t.r[5], 1); // hi
    });

    test('smull', () {
      final t = armRun([aMvnI(1, 0), aMovI(2, 2), aSmull(4, 5, 1, 2)]);
      expect(t.r[4], 0xfffffffe); // -2 lo
      expect(t.r[5], 0xffffffff); // -2 hi
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

    test('unaligned ldr rotates data', () {
      final t = armRun([
        aMovI(0, 2, rot4: 4),
        ...aMovI32(1, 0x11223344),
        aStr(1, 0, 0x10),
        aLdr(2, 0, 0x11), // addr&3==1 -> value ror 8
      ]);
      expect(t.r[2], 0x44112233);
    });

    test('post-index and pre-index writeback', () {
      final t = armRun([
        aMovI(0, 2, rot4: 4),
        aMovI(1, 0x55),
        aStr(1, 0, 4, pre: false), // str r1,[r0],#4
        aLdr(2, 0, 4, up: false), // ldr r2,[r0,#-4]
        aMovI(3, 0x66),
        aStr(3, 0, 4, wb: true), // str r3,[r0,#4]!
      ]);
      expect(t.r[2], 0x55);
      expect(t.r[0], base + 8);
      expect(t.bus.read32(base), 0x55);
      expect(t.bus.read32(base + 8), 0x66);
    });

    test('halfword and signed loads', () {
      final t = armRun([
        aMovI(0, 2, rot4: 4),
        ...aMovI32(1, 0x8081),
        aStrh(1, 0, 0x20),
        aLdrh(2, 0, 0x20),
        aLdrsh(3, 0, 0x20),
        aLdrsb(4, 0, 0x20),
        aLdrsb(5, 0, 0x21),
      ]);
      expect(t.r[2], 0x8081);
      expect(t.r[3], 0xffff8081);
      expect(t.r[4], 0xffffff81);
      expect(t.r[5], 0xffffff80);
    });

    test('stmia/ldmia with writeback', () {
      final t = armRun([
        aMovI(0, 2, rot4: 4),
        aMovI(1, 0x11),
        aMovI(2, 0x22),
        aMovI(3, 0x33),
        aStm(0, 0x0e, wb: true), // stmia r0!, {r1-r3}
        aSubI(4, 0, 12),
        aLdm(4, 0xe0), // ldmia r4, {r5-r7}
      ]);
      expect(t.r[0], base + 12);
      expect(t.r[5], 0x11);
      expect(t.r[6], 0x22);
      expect(t.r[7], 0x33);
      expect(t.bus.read32(base + 4), 0x22);
    });

    test('swp exchanges memory and register', () {
      final t = armRun([
        aMovI(0, 2, rot4: 4),
        aMovI(1, 0x77),
        aStr(1, 0, 0),
        aMovI(2, 0x88),
        aSwp(3, 2, 0),
      ]);
      expect(t.r[3], 0x77);
      expect(t.bus.read32(base), 0x88);
    });
  });

  group('ARM branch / system', () {
    test('b skips instructions', () {
      final t = armRun([
        aMovI(0, 1),
        aB(0), // skips exactly the next word
        aMovI(0, 0xee),
        aMovI(1, 2),
      ]);
      expect(t.r[0], 1);
      expect(t.r[1], 2);
    });

    test('bl sets the link register', () {
      final t = armRun([
        aBl(0), // at 0x08000000, lands at 0x08000008
        aMovI(0, 0xee), // skipped
        aMovI(1, 1),
      ]);
      expect(t.r[14], 0x08000004);
      expect(t.r[0], 0);
      expect(t.r[1], 1);
    });

    test('bx enters thumb state', () {
      final t = thumbRun([tMovsI(0, 0x2a)]);
      expect(t.regs.thumb, true);
      expect(t.r[0], 42);
    });

    test('arm->thumb->arm roundtrip via bx lr', () {
      final t = armRun([
        aMovR(1, 15), // r1 = base+8 (addr of word 2)
        aAddI(1, 1, 13), // -> thumb code at word 5, +1 for thumb bit
        aMovR(14, 15), // lr = addr of word 4
        aBx(1),
        aB(1), // return lands here; jump over the thumb words
        0x2007 | (tLslsI(0, 0, 2) << 16), // movs r0,#7; lsls r0,r0,#2
        tBxLr | (tNop << 16),
        aMovI(2, 1),
      ]);
      expect(t.r[0], 28);
      expect(t.r[2], 1);
      expect(t.regs.thumb, false);
    });

    test('msr flags immediate / mrs readback', () {
      final t = armRun([
        aMsrFlagsI(0xf, rot4: 2), // NZCV = 1111
        aMrs(0),
      ]);
      expect(t.regs.nf, true);
      expect(t.regs.zf, true);
      expect(t.regs.cf, true);
      expect(t.regs.vf, true);
      expect(t.r[0] >> 28, 0xf);
      expect(t.r[0] & 0x1f, CpuMode.sys);
    });

    test('swi enters supervisor mode', () {
      final t = ArmBed([aSwi(0x42)]);
      final oldCpsr = t.regs.cpsr;
      t.stepN(1);
      expect(t.regs.mode, CpuMode.svc);
      expect(t.r[14], 0x08000004); // return address
      expect(t.regs.spsr, oldCpsr);
      expect(t.regs.irqDisabled, true);
      expect(t.regs.pc, 0x10); // vector 0x08 + pipeline offset
    });
  });

  group('Thumb', () {
    test('mov/add/sub/cmp immediates', () {
      final t = thumbRun([
        tMovsI(0, 0xff),
        tAddI8(0, 1), // 0x100
        tSubI3(1, 0, 7), // 0xf9
        tCmpI(1, 0xf9),
      ]);
      expect(t.r[0], 0x100);
      expect(t.r[1], 0xf9);
      expect(t.regs.zf, true);
    });

    test('add/sub register (format 2)', () {
      final t = thumbRun([
        tMovsI(0, 200),
        tMovsI(1, 100),
        tAddR(2, 0, 1),
        tSubR(3, 0, 1),
      ]);
      expect(t.r[2], 300);
      expect(t.r[3], 100);
    });

    test('shifts by immediate (format 1)', () {
      final t = thumbRun([
        tMovsI(0, 1),
        tLslsI(1, 0, 31),
        tLsrsI(2, 1, 31),
        tAsrsI(3, 1, 31),
      ]);
      expect(t.r[1], 0x80000000);
      expect(t.r[2], 1);
      expect(t.r[3], 0xffffffff);
    });

    test('register alu (format 4)', () {
      final t = thumbRun([
        tMovsI(0, 0x0f),
        tMovsI(1, 0x35),
        tAnds(1, 0), // 0x05
        tNegs(2, 1), // -5
        tMovsI(3, 3),
        tMuls(3, 1), // 15
        tMvns(4, 0), // ~0x0f
      ]);
      expect(t.r[1], 5);
      expect(t.r[2], 0xfffffffb);
      expect(t.r[3], 15);
      expect(t.r[4], 0xfffffff0);
    });

    test('hi-register mov/add', () {
      final t = thumbRun([
        tMovsI(0, 5),
        tMovHi(8, 0),
        tMovsI(0, 0),
        tAddHi(0, 8),
        tMovHi(1, 8),
      ]);
      expect(t.r[0], 5);
      expect(t.r[1], 5);
    });

    test('pc-relative literal load', () {
      final t = thumbRun([
        tLdrPc(0, 1), // pool at 0x08000048
        tB(3), // jump over the pool to 0x0800004c
        tNop,
        tNop,
        0xf00d, // pool low half
        0xfeed, // pool high half
        tNop, // 0x0800004c: fall through to the end loop
      ]);
      expect(t.r[0], 0xfeedf00d);
    });

    test('str/ldr immediate offset', () {
      final t = thumbRun([
        tMovsI(0, 2),
        tLslsI(0, 0, 24), // 0x02000000
        tMovsI(1, 0x99),
        tStrI(1, 0, 1), // [r0+4]
        tLdrI(2, 0, 1),
      ]);
      expect(t.r[2], 0x99);
      expect(t.bus.read32(0x02000004), 0x99);
    });

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

    test('conditional branch', () {
      final t = thumbRun([
        tMovsI(0, 0), // Z=1
        tBCond(condEq, 0), // skips the next halfword
        tMovsI(0, 0xee),
      ]);
      expect(t.r[0], 0);
    });

    test('bl sets lr with thumb bit', () {
      final t = thumbRun([
        tMovsI(0, 0x11),
        tBlHi(0),
        tBlLo(1), // target = pc+2: skips the next halfword
        tMovsI(0, 0xee),
        tMovHi(1, 14), // r1 = lr
      ]);
      expect(t.r[0], 0x11);
      expect(t.r[1], 0x08000047); // (addr after bl pair) | thumb bit
    });
  });
}
