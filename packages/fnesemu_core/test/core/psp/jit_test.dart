import 'package:fnesemu_core/src/core/psp/allegrex.dart';
import 'package:fnesemu_core/src/core/psp/memory.dart';
import 'package:fnesemu_core/src/core/psp/psp.dart';
import 'package:fnesemu_core/src/core/psp/psp_jit.dart';
import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

import 'fixture.dart';
import 'psp_test.dart' show buildProgram;

const _entry = 0x08800000;

void _loadProgram(Allegrex cpu, int at, List<int> words) {
  for (final (index, word) in words.indexed) {
    cpu.mem.write32(at + index * 4, word);
  }
  cpu.jumpTo(at);
}

void _expectCpu(Allegrex cpu, Allegrex interpreter) {
  expect(cpu.clocks, interpreter.clocks);
  expect(cpu.pc, interpreter.pc);
  expect(cpu.nextPc, interpreter.nextPc);
  expect(cpu.r, interpreter.r);
  expect(cpu.hi, interpreter.hi);
  expect(cpu.lo, interpreter.lo);
  expect(cpu.linked, interpreter.linked);
  expect(cpu.fcc, interpreter.fcc);
  expect(cpu.vfpuZeroLanes, interpreter.vfpuZeroLanes);
  expect(cpu.v, interpreter.v);
  expect(cpu.fprBits, interpreter.fprBits);
}

void main() {
  for (final native in [false, true]) {
    group(native ? 'native' : 'reference IR',
        skip: native && !JitRuntime.nativeSupported, () {
      late PspJit jit;
      late Allegrex cpu, interpreter;

      setUp(() {
        jit = PspJit.create(native: native, compileThreshold: 1)!;
        cpu =
            Allegrex(jit.memory, regs: jit.regs, fpr: jit.fpr, vfpr: jit.vfpr);
        interpreter = Allegrex(PspMemory());
      });

      tearDown(() => jit.dispose());

      int runCompiled([int budget = 256]) {
        final before = cpu.clocks;
        jit.run(cpu, budget);
        final spent = cpu.clocks - before;
        expect(spent, inInclusiveRange(0, budget));
        for (var i = 0; i < spent; i++) {
          expect(interpreter.step(), isTrue);
        }
        _expectCpu(cpu, interpreter);
        return spent;
      }

      test('integer, raw FPU transfers, memory mirrors and branch slots', () {
        final a = Asm(_entry);
        a.li(Reg.t0, 0x48830000);
        a.li(Reg.t1, 0x44208000);
        a.li(Reg.t2, 0x7f800001);
        a.i(0x11, 4, Reg.t2, 3 << 11); // MTC1
        a.i(0x39, Reg.t0, 3, 0); // SWC1
        a.i(0x31, Reg.t0, 4, 0); // LWC1
        a.i(0x11, 0, Reg.t3, 4 << 11); // MFC1
        a.sw(Reg.t3, 0, Reg.t1);
        a.lb(Reg.t4, 2, Reg.t1);
        a.li(Reg.a0, -2);
        a.r(Reg.a0, Reg.t2, 0, 0, 0x18); // MULT
        a.r(0, 0, Reg.a1, 0, 0x10); // MFHI
        a.branch(0x14, Reg.a0, 0, 'end'); // BEQL misses
        a.syscall(1); // The missed branch annuls even an interpreter-only slot.
        a.branch(0x15, Reg.a0, 0, 'call'); // BNEL is taken
        a.addiu(Reg.a0, 0, 0); // Changes the input to the branch.
        a.addiu(Reg.a2, 0, 99);
        a.label('call');
        a.liAbs(Reg.t5, 'target');
        a.jalr(Reg.t5, Reg.t5);
        a.addiu(Reg.a3, Reg.t5, 0); // Reads the new link.
        a.label('end');
        a.addiu(Reg.a2, 0, 100);
        a.label('target');
        a.syscall(2);
        final words = a.finish();
        _loadProgram(cpu, _entry, words);
        _loadProgram(interpreter, _entry, words);

        cpu.linked = interpreter.linked = true;
        expect(runCompiled(), greaterThan(0));
        expect(cpu.pc, a.addr('target'));
        expect(cpu.r[Reg.a3], a.addr('end'));
        expect(cpu.r[Reg.a2], 0);
        expect(cpu.linked, isFalse);
        expect(cpu.mem.read32(0x08830000), 0x7f800001);
        expect(cpu.mem.read32(0x04008000), 0x7f800001);
      });

      test('a load exit in a delay slot restores the pre-branch link', () {
        final a = Asm(_entry);
        a.addiu(Reg.t0, 0, 1);
        a.label('branch');
        a.jalr(Reg.t1, Reg.t1);
        a.lw(Reg.v0, 0, Reg.t0); // Unaligned and unmapped.
        a.nop();
        a.label('target');
        a.syscall(0);
        final words = a.finish();
        _loadProgram(cpu, _entry, words);
        _loadProgram(interpreter, _entry, words);
        cpu.r[Reg.t1] = interpreter.r[Reg.t1] = a.addr('target');

        expect(runCompiled(), 1);
        expect(cpu.pc, a.addr('branch'));
        expect(cpu.r[Reg.t1], a.addr('target'));
        expect(cpu.step(), isTrue);
        expect(interpreter.step(), isTrue);
        expect(cpu.pc, a.addr('branch') + 4);
        expect(runCompiled(), 0);
        expect(cpu.step(), isTrue);
        expect(interpreter.step(), isTrue);
        _expectCpu(cpu, interpreter);
      });

      test('floating-point arithmetic, condition codes and vector transfers',
          () {
        final a = Asm(_entry);
        void fp(int format, int ft, int fs, int fd, int fn) =>
            a.i(0x11, format, ft, fs << 11 | fd << 6 | fn);

        fp(0x14, 0, 0, 3, 0x20); // CVT.S.W of the largest signed word.
        fp(0x10, 2, 1, 4, 0x02); // MUL.S
        fp(0x10, 0, 4, 5, 0x0d); // TRUNC.W.S
        fp(0x10, 7, 6, 8, 0x32); // C.EQ.S compares +0 and -0 in FCC2.
        fp(0x10, 2, 8, 12, 0x31); // C.UN.S compares a NaN in FCC3.
        a.branch(0x11, 8, 11, 'vector'); // BC1TL on FCC2
        a.addiu(Reg.v0, Reg.zero, 7);
        a.addiu(Reg.v0, Reg.zero, 9);
        a.label('vector');
        a.li(Reg.t0, 0x40010000);
        a.i(0x36, Reg.t0, 3, 1); // LV.Q into a row.
        a.i(0x3e, Reg.t0, 3, 17); // SV.Q of that row to the next quad.
        a.syscall(0);
        final words = a.finish();
        for (final target in [cpu, interpreter]) {
          _loadProgram(target, _entry, words);
          target.fprBits.setAll(0, [
            0x7fffffff,
            0xbfc00000,
            0x40000000,
            0,
            0,
            0,
            0,
            0x80000000,
            0x7f800001
          ]);
          for (var i = 0; i < 4; i++) {
            target.mem.write32(PspMemory.scratchAt + i * 4, 0x7f800001 + i);
          }
        }

        expect(runCompiled(), words.length - 2);
        expect(cpu.r[Reg.v0], 7);
        expect(cpu.fcc, (1 << 2) | (1 << 3));
        expect(cpu.fprBits[5], 0xfffffffd);
        expect(cpu.mem.readBytes(PspMemory.scratchAt + 16, 16),
            cpu.mem.readBytes(PspMemory.scratchAt, 16));
      });

      test('stores to a mirrored code page update the next instruction', () {
        const vramCode = PspMemory.vramAt;
        final a = Asm(vramCode);
        a.sw(Reg.t1, 4, Reg.t0);
        a.addiu(Reg.v0, 0, 0);
        a.syscall(0);
        final words = a.finish();
        _loadProgram(cpu, vramCode, words);
        _loadProgram(interpreter, vramCode, words);
        cpu.r[Reg.t0] = interpreter.r[Reg.t0] = 0x44600000;
        for (var i = 1; i <= JitCodeMemory.storeExitLimit + 1; i++) {
          cpu.jumpTo(vramCode);
          interpreter.jumpTo(vramCode);
          cpu.r[Reg.t1] = interpreter.r[Reg.t1] = 0x24020000 | i;
          final spent = runCompiled();
          if (i <= JitCodeMemory.storeExitLimit) {
            expect(spent, 0);
            expect(cpu.step(), isTrue);
            expect(interpreter.step(), isTrue);
            expect(runCompiled(), 1);
          } else {
            expect(spent, 2);
          }
          expect(cpu.r[Reg.v0], i);
          expect(cpu.pc, vramCode + 8);
        }
      });
    });
  }

  test('frame execution and interpreter share clocks and checkpoints',
      skip: !JitRuntime.nativeSupported, () {
    final rom = buildProgram(workerDelay: 10000, spinWhileWaiting: true);
    final compiled = Psp(jit: true)..setRom(rom);
    final interpreted = Psp(jit: false)..setRom(rom);
    addTearDown(compiled.dispose);
    addTearDown(interpreted.dispose);

    var stopped = false;
    for (var line = 0; line < 3 * compiled.scanlinesInFrame; line++) {
      final expected = interpreted.exec(false);
      final actual = compiled.exec(false);
      expect(actual.stopped, expected.stopped);
      expect(actual.scanlineRendered, expected.scanlineRendered);
      _expectCpu(compiled.cpu, interpreted.cpu);
      if (actual.stopped) {
        stopped = true;
        break;
      }
      if (line == 2 * compiled.scanlinesInFrame + 30) {
        expect(compiled.jitClocks, greaterThan(0));
        compiled.loadState(interpreted.saveState());
        expect(compiled.jitClocks, 0);
      }
    }
    expect(stopped, isTrue);
    expect(compiled.saveState(), interpreted.saveState());
  });

  test('a hot loop stops at the scanline deadline and supports single stepping',
      skip: !JitRuntime.nativeSupported, () {
    final a = Asm(_entry);
    a.label('loop');
    a.addiu(Reg.v0, Reg.v0, 1);
    a.jTo('loop');
    a.addiu(Reg.v1, Reg.v1, 1);
    final (rom, _) = buildTestElf(code: a.finish());
    final compiled = Psp(jit: true)..setRom(rom);
    final interpreted = Psp(jit: false)..setRom(rom);
    addTearDown(compiled.dispose);
    addTearDown(interpreted.dispose);

    compiled.exec(false);
    interpreted.exec(false);
    expect(compiled.cpuClocks, compiled.clocksInScanline);
    expect(compiled.jitClocks, greaterThan(0));
    _expectCpu(compiled.cpu, interpreted.cpu);
    final jitClocks = compiled.jitClocks;
    compiled.exec(true);
    interpreted.exec(true);
    expect(compiled.jitClocks, jitClocks);
    _expectCpu(compiled.cpu, interpreted.cpu);

    compiled.jitSuspended = true;
    compiled.exec(false);
    interpreted.exec(false);
    expect(compiled.jitClocks, jitClocks);
    _expectCpu(compiled.cpu, interpreted.cpu);
  });
}
