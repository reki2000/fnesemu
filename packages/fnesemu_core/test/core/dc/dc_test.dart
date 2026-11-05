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

  test('compiled single FPU arithmetic matches the interpreter in both rounding modes',
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
      var b = i % 3 == 0 ? (a ^ 0x80000000) + random.nextInt(8) - 3 : single(random);
      if (i % 5 == 0) b = (a & 0x80000000) | ((a & 0x7fffffff) - (random.nextInt(30) << 23));
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
}
