import 'dart:math';
import 'dart:typed_data';

import 'package:fnesemu_core/core_factory.dart';
import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:fnesemu_core/src/core/dc/module.dart';
import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

void main() {
  test('system reset request is applied at the execution boundary', () {
    final bios = Uint8List(DcBus.biosSize)..[0] = 0x09;
    final core = Dc(jit: false)..setBiosFiles([bios]);
    addTearDown(core.dispose);
    core.cpu.pc = 0x8c000100;
    core.bus.write16(0x8c000100, 0x0009);
    core.bus.write32(0xa05f6890, 0x1234);
    core.exec(true);
    expect(core.cpu.pc, 0x8c000102);
    core.bus.write32(0xa05f6890, 0x7611);
    expect(core.cpu.pc, 0x8c000102);
    expect(() => core.saveState(), throwsA(isA<Exception>()));
    expect(core.exec(true).stopped, isFalse);
    expect(core.cpu.pc, 0xa0000000);
    expect(core.bus.bios[0], 0x09);
    expect(core.bus.read16(0x8c000100), 0x0009);
    final saved = core.saveState();
    core.bus.write32(0xa05f6890, 0x7611);
    core.loadState(saved);
    core.exec(true);
    expect(core.cpu.pc, 0xa0000002);
  });

  test('guest reset write completes before restarting the BIOS', () {
    final bios = Uint8List(DcBus.biosSize)
      ..[0] = 0x12
      ..[1] = 0x20;
    final core = Dc(jit: false)..setBiosFiles([bios]);
    addTearDown(core.dispose);
    core.cpu.r[0] = 0xa05f6890;
    core.cpu.r[1] = 0x7611;
    expect(core.exec(true).stopped, isFalse);
    expect(core.cpu.pc, 0xa0000000);
    expect(core.cpu.r[0], 0);
  });

  test(
      'Core scheduling clocks TMU and accepts its interrupt at the next boundary',
      () {
    final core = Dc()
      ..setRom(Uint8List.fromList(
          List.generate(40, (index) => index.isEven ? 0x09 : 0x00)));
    addTearDown(core.dispose);
    core.cpu.sr = 0x40000000;
    core.cpu.vbr = 0x8c020000;
    core.bus.write16(0xffd00004, 0xf000);
    core.bus.write32(0xffd8000c, 0);
    core.bus.write16(0xffd80010, 0x20);
    core.bus.write8(0xffd80004, 1);
    for (var i = 0; i < 16; i++) {
      final result = core.exec(true);
      expect(result.executed(0), isTrue);
      expect(result.elapsedClocks, 1);
    }
    expect(core.bus.tmu.interruptPending(0), isTrue);
    final entry = core.exec(true);
    expect(entry.executed(0), isFalse);
    expect(entry.elapsedClocks, 1);
    expect(core.cpu.spc, Dc.programAddress + 32);
    expect(core.cpu.pc, 0x8c020600);
    expect(core.bus.intevt, 0x400);
    core.reset();
    expect(core.bus.tmu.interruptPending(0), isFalse);
    expect(core.bus.read16(0xffd00004), 0);
  });

  test('boot ROM starts at reset vector; invalid replacement is atomic', () {
    final core = Dc();
    addTearDown(core.dispose);
    final bios = Uint8List(DcBus.biosSize)
      ..[0] = 0x2a
      ..[1] = 0xe1;
    core.setBiosFiles([bios]);
    bios[0] = 0;
    expect(core.exec(true).stopped, isFalse);
    expect(core.cpu.r[1], 42);
    expect(core.cpu.pc, 0xa0000002);
    expect(() => core.setBiosFiles([]), throwsArgumentError);
    expect(() => core.setBiosFiles([Uint8List(16)]), throwsArgumentError);
    expect(core.cpu.pc, 0xa0000002);
    expect(core.bus.bios[0], 42);
  });

  test('compiled SH-4 code matches the interpreter', () {
    // A loop mixing ALU, memory, GBR, store-queue, FPU and call forms.
    final words = <int>[
      0xd81d,
      0xd91e,
      0xdb1e,
      0xdc1f,
      0xed0c,
      0x2cd2,
      0xea14,
      0x30ac,
      0x6107,
      0x0018,
      0x310e,
      0x321f,
      0x332a,
      0x643a,
      0x314d,
      0x050a,
      0x3215,
      0x061a,
      0xe7fd,
      0x457c,
      0x467d,
      0x265c,
      0x0729,
      0x221d,
      0x6328,
      0xf3fd,
      0xf82b,
      0xf3fd,
      0x2806,
      0x6395,
      0x481b,
      0x0429,
      0x2217,
      0x3214,
      0xf31e,
      0x405a,
      0xf12d,
      0xf210,
      0xf5ed,
      0xf312,
      0xf33d,
      0x0c5a,
      0xfbfd,
      0xf82b,
      0xfbfd,
      0x2b02,
      0x0b83,
      0x18c1,
      0x5d81,
      0x481e,
      0xc202,
      0xb004,
      0xf3fd, // FSCHG in the BSR slot.
      0x4a10,
      0x8bcf,
      0xaffe,
      0x0009,
      0x000b,
      0x7e01,
      0x0009,
      0x0000,
      0x8c20,
      0x0000,
      0x8c18,
      0x0000,
      0xe010,
      0x0038,
      0xff00,
    ];
    Dc run(bool jit) {
      final core = Dc(jit: jit);
      addTearDown(core.dispose);
      core.setRom(Uint8List.fromList([
        for (final w in words) ...[w & 255, w >> 8]
      ]));
      // Round to nearest, so the compiled FPU arithmetic runs natively.
      core.cpu.fpscr = 0x40000;
      core.runFrame(8);
      return core;
    }

    final compiled = run(true), interpreted = run(false);
    if (JitRuntime.nativeSupported) expect(compiled.jitClocks, greaterThan(0));
    expect(compiled.stopReason, isNull);
    expect(interpreted.stopReason, isNull);
    for (final (a, b) in [
      (compiled.cpu.r, interpreted.cpu.r),
      (compiled.cpu.fr, interpreted.cpu.fr),
      (compiled.cpu.xf, interpreted.cpu.xf),
      (compiled.bus.ram, interpreted.bus.ram),
    ]) {
      expect(a, b);
    }
    expect([compiled.cpu.sr, compiled.cpu.fpscr, compiled.cpu.gbr],
        [interpreted.cpu.sr, interpreted.cpu.fpscr, interpreted.cpu.gbr]);
    expect([compiled.cpu.mach, compiled.cpu.macl, compiled.cpu.fpul],
        [interpreted.cpu.mach, interpreted.cpu.macl, interpreted.cpu.fpul]);
  });

  test(
      'compiled single FPU arithmetic matches the interpreter in both rounding modes',
      () {
    // Per iteration: load a, b, c; FADD, FSUB, FMUL, FMAC and FLOAT on them,
    // storing every result and FPSCR.
    const iterations = 120;
    final code = <int>[];
    void emit(int word) => code.add(word);
    // r4 = input pointer and r5 = output pointer, from the literals below.
    emit(0xd400); // mov.l @(disp,pc),r4, patched below
    emit(0xd500); // mov.l @(disp,pc),r5, patched below
    emit(0xe600 | iterations); // mov #iterations,r6
    final loop = code.length;
    emit(0xf049); // fmov.s @r4+,fr0
    emit(0xf149); // fmov.s @r4+,fr1
    emit(0xf249); // fmov.s @r4+,fr2
    void store() {
      emit(0xf53a); // fmov.s fr3,@r5
      emit(0x7504); // add #4,r5
      emit(0x016a); // sts fpscr,r1
      emit(0x2512); // mov.l r1,@r5
      emit(0x7504); // add #4,r5
    }

    for (final op in [0xf310, 0xf311, 0xf312]) {
      emit(0xf30c); // fmov fr0,fr3
      emit(op); // fadd / fsub / fmul fr1,fr3
      store();
    }
    emit(0xf32c); // fmov fr2,fr3
    emit(0xf31e); // fmac fr0,fr1,fr3
    store();
    emit(0xf01d); // flds fr0,fpul
    emit(0xf32d); // float fpul,fr3
    store();
    emit(0x4610); // dt r6
    final branch = code.length;
    emit(0x8b00 | ((loop - branch - 2) & 255)); // bf loop
    emit(0xaffe); // bra self
    emit(0x0009); // nop
    while (code.length * 2 % 4 != 0) {
      emit(0x0009);
    }
    final pool = code.length * 2;
    code[0] = 0xd400 | ((pool - 4) ~/ 4);
    code[1] = 0xd500 | ((pool + 4 - 4) ~/ 4);
    emit(0x0000); // r4 = 0x8c020000
    emit(0x8c02);
    emit(0x4000); // r5 = 0x8c024000
    emit(0x8c02);

    final random = Random(11);
    int single(Random r) {
      final kind = r.nextInt(4);
      final exponent = 100 + r.nextInt(50);
      final fraction = kind == 0 ? 0 : r.nextInt(1 << 23);
      return (r.nextBool() ? 0x80000000 : 0) | (exponent << 23) | fraction;
    }

    final inputs = <int>[];
    for (var i = 0; i < iterations; i++) {
      final a = single(random);
      // Every third pair cancels or ties: b is a with a small change.
      var b = i % 3 == 0
          ? (a ^ 0x80000000) + random.nextInt(8) - 3
          : single(random);
      if (i % 5 == 0)
        b = (a & 0x80000000) | ((a & 0x7fffffff) - (random.nextInt(30) << 23));
      inputs.addAll([a, b & 0xffffffff, single(random)]);
    }
    for (final control in [0x40001, 0x40000, 0x00001]) {
      List<int> run(bool jit) {
        final core = Dc(jit: jit);
        addTearDown(core.dispose);
        core.setRom(Uint8List.fromList([
          for (final w in code) ...[w & 255, w >> 8]
        ]));
        for (var i = 0; i < inputs.length; i++) {
          core.bus.write32(0x8c020000 + 4 * i, inputs[i]);
        }
        core.cpu.fpscr = control;
        core.runFrame(60);
        expect(core.stopReason, isNull);
        expect(core.cpu.r[6], 0, reason: 'the loop did not finish');
        return [
          for (var i = 0; i < iterations * 10; i++)
            core.bus.read32(0x8c024000 + 4 * i)
        ];
      }

      final compiled = run(true), interpreted = run(false);
      for (var i = 0; i < compiled.length; i++) {
        expect(compiled[i], interpreted[i],
            reason: 'control=${control.toRadixString(16)} word $i '
                '(iteration ${i ~/ 10}, slot ${i % 10})');
      }
    }
  });
  test('compiled FTRV and FIPR match the interpreter in both rounding modes',
      () {
    // Per iteration: a 4x4 matrix and a vector; FTRV, then FIPR on the
    // matrix rows, storing every result and FPSCR.
    const iterations = 60;
    final code = <int>[];
    void emit(int word) => code.add(word);
    emit(0xd400); // mov.l @(disp,pc),r4, patched below
    emit(0xd500); // mov.l @(disp,pc),r5, patched below
    emit(0xe600 | iterations); // mov #iterations,r6
    final loop = code.length;
    void load(int register) => emit(0xf049 | (register << 8)); // fmov.s @r4+
    void store(int register) {
      emit(0xf50a | (register << 4)); // fmov.s frN,@r5
      emit(0x7504); // add #4,r5
    }

    void storeStatus() {
      emit(0x016a); // sts fpscr,r1
      emit(0x2512); // mov.l r1,@r5
      emit(0x7504); // add #4,r5
    }

    for (var i = 0; i < 16; i++) {
      load(i);
    }
    emit(0xfbfd); // frchg: the matrix moves to XMTRX
    for (var i = 0; i < 4; i++) {
      load(i);
    }
    emit(0xf1fd); // ftrv xmtrx,fv0
    for (var i = 0; i < 4; i++) {
      store(i);
    }
    storeStatus();
    emit(0xfbfd); // frchg: the matrix is back in fr0..fr15
    emit(0xf1ed); // fipr fv4,fv0
    store(3);
    storeStatus();
    emit(0x4610); // dt r6
    final branch = code.length;
    emit(0x8b00 | ((loop - branch - 2) & 255)); // bf loop
    emit(0xaffe); // bra self
    emit(0x0009); // nop
    while (code.length * 2 % 4 != 0) {
      emit(0x0009);
    }
    final pool = code.length * 2;
    code[0] = 0xd400 | ((pool - 4) ~/ 4);
    code[1] = 0xd500 | ((pool + 4 - 4) ~/ 4);
    emit(0x0000); // r4 = 0x8c020000
    emit(0x8c02);
    emit(0x4000); // r5 = 0x8c024000
    emit(0x8c02);

    // Short mantissas in a narrow exponent range keep every double sum exact,
    // so the compiled code must equal the exact model.
    final random = Random(23);
    int value() =>
        (random.nextBool() ? 0x80000000 : 0) |
        ((120 + random.nextInt(8)) << 23) |
        (random.nextInt(1 << 11) << 12);
    final inputs = [for (var i = 0; i < iterations * 20; i++) value()];
    for (final control in [0x40001, 0x40000, 0x00001]) {
      List<int> run(bool jit) {
        final core = Dc(jit: jit);
        addTearDown(core.dispose);
        core.setRom(Uint8List.fromList([
          for (final w in code) ...[w & 255, w >> 8]
        ]));
        for (var i = 0; i < inputs.length; i++) {
          core.bus.write32(0x8c020000 + 4 * i, inputs[i]);
        }
        core.cpu.fpscr = control;
        core.runFrame(60);
        expect(core.stopReason, isNull);
        expect(core.cpu.r[6], 0, reason: 'the loop did not finish');
        return [
          for (var i = 0; i < iterations * 7; i++)
            core.bus.read32(0x8c024000 + 4 * i)
        ];
      }

      final compiled = run(true), interpreted = run(false);
      for (var i = 0; i < compiled.length; i++) {
        expect(compiled[i], interpreted[i],
            reason: 'control=${control.toRadixString(16)} word $i '
                '(iteration ${i ~/ 7}, slot ${i % 7})');
      }
    }
  });
  test('compiled code with the MMU on matches the interpreter', () {
    // A loop in P2 that reads and writes P1 RAM, and RAM through a TLB entry
    // whose virtual page has other contents at its untranslated address.
    final code = <int>[];
    void emit(int word) => code.add(word);
    emit(0xd400); // mov.l @(disp,pc),r4: the virtual address
    emit(0xd500); // mov.l @(disp,pc),r5: the P1 address
    emit(0xe614); // mov #20,r6
    final loop = code.length;
    emit(0x6142); // mov.l @r4,r1
    emit(0x7101); // add #1,r1
    emit(0x2512); // mov.l r1,@r5
    emit(0x6252); // mov.l @r5,r2
    emit(0x312c); // add r2,r1
    emit(0x2412); // mov.l r1,@r4
    emit(0x7404); // add #4,r4
    emit(0x7504); // add #4,r5
    emit(0x4610); // dt r6
    final branch = code.length;
    emit(0x8b00 | ((loop - branch - 2) & 255)); // bf loop
    emit(0xaffe); // bra self
    emit(0x0009); // nop
    while (code.length * 2 % 4 != 0) {
      emit(0x0009);
    }
    final pool = code.length * 2;
    code[0] = 0xd400 | ((pool - 4) ~/ 4);
    code[1] = 0xd500 | ((pool + 4 - ((2 * 1 + 4) & ~3)) ~/ 4);
    emit(0x0000); // r4 = 0x0c040000
    emit(0x0c04);
    emit(0x0000); // r5 = 0x8c030000
    emit(0x8c03);

    Dc run(bool jit) {
      final core = Dc(jit: jit);
      addTearDown(core.dispose);
      core.setRom(Uint8List.fromList([
        for (final w in code) ...[w & 255, w >> 8]
      ]));
      for (var i = 0; i < 20; i++) {
        core.bus.write32(0x0c020000 + 4 * i, 100 + i); // translated
        core.bus.write32(0x0c040000 + 4 * i, 5000 + i); // untranslated alias
      }
      core.bus.write32(0xf6000000, 0x0c040000);
      core.bus.write32(0xf7000000, 0x0c020000 | 0x174);
      core.bus.mmucr = 1;
      core.runFrame(8);
      return core;
    }

    final compiled = run(true), interpreted = run(false);
    if (JitRuntime.nativeSupported) expect(compiled.jitClocks, greaterThan(0));
    expect(compiled.stopReason, interpreted.stopReason);
    expect(compiled.cpu.r, interpreted.cpu.r);
    expect(compiled.bus.ram, interpreted.bus.ram);
    // The translated reads saw the TLB's page, not the alias.
    expect(interpreted.bus.read32(0x8c030000), 101);
  });

  for (final user in [false, true]) {
    test('compiled store-queue stores with the MMU on match the interpreter '
        '(${user ? 'user' : 'privileged'} mode)', () {
      // The code fills store queue 0 and flushes it 100 times; PREF goes
      // through a TLB entry for the store-queue page. User code runs from
      // virtual 0x10000 with MMUCR.SQMD clear.
      const code = [
        0xd407, // mov.l @(pool,pc),r4: 0xe0000000
        0xe764, // mov #100,r7
        0xe10a, // mov #10,r1
        0xe608, // outer: mov #8,r6
        0x2412, // inner: mov.l r1,@r4
        0x7103, // add #3,r1
        0x7404, // add #4,r4
        0x4610, // dt r6
        0x8bfa, // bf inner
        0x74e0, // add #-32,r4
        0x0483, // pref @r4
        0x4710, // dt r7
        0x8bf5, // bf outer
        0xaffe, // bra self
        0x0009, // nop
        0x0009, // nop
        0x0000, 0xe000, // pool: 0xe0000000
      ];

      Dc run(bool jit) {
        final core = Dc(jit: jit);
        addTearDown(core.dispose);
        core.setRom(Uint8List.fromList([
          for (final w in code) ...[w & 255, w >> 8]
        ]));
        core.bus.write32(0xf6000000, 0xe0000000);
        core.bus.write32(0xf7000000, 0x0c030000 | 0x174);
        if (user) {
          for (final (i, word) in code.indexed) {
            core.bus.write16(0xac050000 + 2 * i, word);
          }
          core.bus.write32(0xf6000100, 0x00010000);
          core.bus.write32(0xf7000100, 0x0c050000 | 0x174);
        }
        core.bus.mmucr = 1;
        if (user) {
          core.cpu
            ..sr = 0xf0
            ..pc = 0x00010000;
        }
        core.runFrame(8);
        return core;
      }

      final compiled = run(true), interpreted = run(false);
      if (JitRuntime.nativeSupported) {
        expect(compiled.jitClocks, greaterThan(0));
      }
      expect(compiled.stopReason, interpreted.stopReason);
      expect(compiled.cpu.r, interpreted.cpu.r);
      expect(compiled.bus.ram, interpreted.bus.ram);
      expect(interpreted.bus.read32(0x8c030000), 10 + 3 * 792);
      expect(interpreted.bus.read32(0x8c03001c), 10 + 3 * 799);
    });
  }

  test('compiled user code in translated pages follows TLB changes', () {
    // User code at virtual 0x10000 adds to the words of virtual 0x20000,
    // then spins. It runs again after both pages move.
    List<int> program(int increment) => [
          0xd404, // mov.l @(pool,pc),r4
          0xe614, // mov #20,r6
          0x6142, // loop: mov.l @r4,r1
          0x7100 | increment, // add #increment,r1
          0x2412, // mov.l r1,@r4
          0x7404, // add #4,r4
          0x4610, // dt r6
          0x8bf9, // bf loop
          0xaffe, // bra self
          0x0009, // nop
          0x0000, 0x0002, // pool: 0x00020000
        ];
    const flags = 0x174; // Valid, 4 KiB, user read and write, dirty.

    Dc run(bool jit) {
      final core = Dc(jit: jit);
      addTearDown(core.dispose);
      core.setRom(Uint8List.fromList([0xfe, 0xaf, 0x09, 0x00]));
      for (final (base, increment) in [(0x0c050000, 1), (0x0c060000, 2)]) {
        for (final (i, word) in program(increment).indexed) {
          core.bus.write16(0xa0000000 | base + 2 * i, word);
        }
      }
      core.bus.write32(0xf6000000, 0x00010000);
      core.bus.write32(0xf7000000, 0x0c050000 | flags);
      core.bus.write32(0xf6000100, 0x00020000);
      core.bus.write32(0xf7000100, 0x0c020000 | flags);
      core.bus.mmucr = 1;
      core.cpu
        ..sr = 0xf0
        ..pc = 0x00010000;
      core.runFrame(4);
      // Both pages move: the code to a copy that adds two.
      core.bus.write32(0xf7000000, 0x0c060000 | flags);
      core.bus.write32(0xf7000100, 0x0c040000 | flags);
      core.bus.mmucr = 5; // Invalidate the ITLB, which keeps the old page.
      core.bus.write32(0xf6000000, 0x00010000);
      core.bus.write32(0xf7000000, 0x0c060000 | flags);
      core.bus.write32(0xf6000100, 0x00020000);
      core.bus.write32(0xf7000100, 0x0c040000 | flags);
      core.cpu.pc = 0x00010000;
      core.runFrame(8);
      // Only the data entry changes, which the UTLB alone holds.
      core.bus.write32(0xf7000100, 0x0c030000 | flags);
      core.cpu.pc = 0x00010000;
      core.runFrame(12);
      return core;
    }

    final compiled = run(true), interpreted = run(false);
    if (JitRuntime.nativeSupported) expect(compiled.jitClocks, greaterThan(0));
    expect(compiled.stopReason, interpreted.stopReason);
    expect(compiled.cpu.r, interpreted.cpu.r);
    expect(compiled.bus.ram, interpreted.bus.ram);
    expect(interpreted.bus.read32(0x8c020000), 1);
    expect(interpreted.bus.read32(0x8c040000), 2);
    expect(interpreted.bus.read32(0x8c030000), 2);
  });
}
