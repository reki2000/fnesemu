// A no-BIOS MIPS/R5900 FizzBuzz test for the current EE JIT.
// The output is 30 32-bit words: positive integers, -1=Fizz, -2=Buzz,
// -3=FizzBuzz. Native JIT results are checked against the interpreter.
import 'dart:io';

import 'package:fnesemu_core/src/core/ps2/bus.dart';
import 'package:fnesemu_core/src/core/ps2/jit/ps2_jit.dart';
import 'package:fnesemu_core/src/core/ps2/jit/r5900_translator.dart';
import 'package:fnesemu_core/src/core/ps2/r5900/r5900.dart';
import 'package:mp_jit_recompiler/src/optimizer.dart';
import 'package:mp_jit_recompiler/src/native_env.dart';
import 'package:mp_jit_recompiler/src/x64/backend.dart';

const codeBase = 0x100000;
const dataBase = 0x200000;

class Mips {
  final words = <int>[];
  final labels = <String, int>{};
  final branches = <(int, String)>[];
  final jumps = <(int, String)>[];

  void label(String name) => labels[name] = words.length;
  void emit(int word) => words.add(word & 0xffffffff);
  void nop() => emit(0);
  void i(int op, int rs, int rt, int imm) =>
      emit(op << 26 | rs << 21 | rt << 16 | (imm & 0xffff));
  void r(int fn, int rs, int rt, int rd) =>
      emit(rs << 21 | rt << 16 | rd << 11 | fn);
  void addiu(int rt, int rs, int imm) => i(9, rs, rt, imm);
  void lui(int rt, int imm) => i(15, 0, rt, imm);
  void addu(int rd, int rs, int rt) => r(33, rs, rt, rd);
  void div(int rs, int rt) => r(26, rs, rt, 0);
  void mfhi(int rd) => r(16, 0, 0, rd);
  void sw(int rt, int offset, int rs) => i(43, rs, rt, offset);
  void bne(int rs, int rt, String dest) {
    branches.add((words.length, dest));
    i(5, rs, rt, 0);
  }
  void j(String dest) {
    jumps.add((words.length, dest));
    emit(2 << 26);
  }

  List<int> finish() {
    for (final (at, target) in branches) {
      final offset = labels[target]! - at - 1;
      if (offset < -32768 || offset > 32767) {
        throw StateError('branch offset overflow');
      }
      words[at] |= offset & 0xffff;
    }
    for (final (at, target) in jumps) {
      final address = codeBase + labels[target]! * 4;
      words[at] |= (address >>> 2) & 0x03ffffff;
    }
    return words;
  }
}

Mips makeProgram() {
  final a = Mips();
  // s0=n, s1=limit, s2=3, s3=5, s4=output pointer,
  // t0/t1=remainder, t2=output value.
  a.addiu(16, 0, 1);
  a.addiu(17, 0, 31);
  a.addiu(18, 0, 3);
  a.addiu(19, 0, 5);
  a.lui(20, dataBase >>> 16);
  a.label('loop');
  a.div(16, 18);
  a.mfhi(8);
  a.bne(8, 0, 'check5');
  a.nop();
  a.div(16, 19);
  a.mfhi(9);
  a.bne(9, 0, 'fizz');
  a.nop();
  a.addiu(10, 0, -3);
  a.j('store');
  a.nop();
  a.label('fizz');
  a.addiu(10, 0, -1);
  a.j('store');
  a.nop();
  a.label('check5');
  a.div(16, 19);
  a.mfhi(9);
  a.bne(9, 0, 'number');
  a.nop();
  a.addiu(10, 0, -2);
  a.j('store');
  a.nop();
  a.label('number');
  a.addu(10, 16, 0);
  a.label('store');
  a.sw(10, 0, 20);
  a.addiu(20, 20, 4);
  a.addiu(16, 16, 1);
  a.bne(16, 17, 'loop');
  a.nop();
  a.label('done');
  a.j('done');
  a.nop();
  a.finish();
  return a;
}

void load(R5900 cpu, Ps2Bus bus, List<int> words) {
  cpu.reset();
  for (var i = 0; i < words.length; i++) {
    bus.write32(codeBase + i * 4, words[i]);
  }
  cpu.jumpTo(codeBase);
}

List<int> results(Ps2Bus bus) => [
  for (var i = 0; i < 30; i++)
    bus.read32(dataBase + i * 4).toSigned(32),
];

List<int> expected() => [
  for (var i = 1; i <= 30; i++)
    if (i % 15 == 0) -3 else if (i % 3 == 0) -1 else if (i % 5 == 0) -2 else i
];

String asFizzBuzz(List<int> values) => values.map((v) => switch (v) {
  -1 => 'Fizz',
  -2 => 'Buzz',
  -3 => 'FizzBuzz',
  _ => '$v',
}).join(' ');

class DumpEnv implements NativeEnv {
  int slots = 0;
  @override bool get win64 => false;
  @override int get blockEntryFn => 0;
  @override int get addrMask => 0x1fffffff;
  @override int get pageShift => 12;
  @override int get exitStub => 0x100000000;
  @override int get readFn => 0x100000100;
  @override int get writeFn => 0x100000200;
  @override int helperFn(int id) => 0x100000300;
  // Code guards excluded only from the standalone assembly listing;
  // the real Ps2Jit execution retains them.
  @override int? guardAddr(int guestAddr) => null;
  @override int slotFor(int pc, int tag) => slots++;
}

void dumpX64(Mips program) {
  final translator = R5900Translator(
    fetch: (pc) {
      final index = (pc - codeBase) ~/ 4;
      if ((pc - codeBase) < 0 || ((pc - codeBase) & 3) != 0 ||
          index >= program.words.length) return null;
      return program.words[index];
    },
    protect: (_) {},
  );
  for (final name in ['loop', 'fizz', 'check5', 'store']) {
    final pc = codeBase + program.labels[name]! * 4;
    final block = translator.translate(pc);
    if (block == null) throw StateError('cannot translate $name');
    final optimized = optimizeIrBlock(block);
    final env = DumpEnv();
    final bytes = X64Backend.compile(optimized, 0x100010000, env);
    final filename = 'fizz_${name}_x64.bin';
    File(filename).writeAsBytesSync(bytes);
    print('X64_DUMP name=$name pc=0x${pc.toRadixString(16)} '
          'mips_block_cost=${optimized.cost} '
          'ir_values=${optimized.insts.length} '
          'x64_bytes=${bytes.length} file=$filename');
  }
}

void main() {
  final program = makeProgram();
  final done = codeBase + program.labels['done']! * 4;
  print('MIPS instruction words=${program.words.length}; done=0x${done.toRadixString(16)}');
  for (final e in program.labels.entries) {
    print('LABEL ${e.key}: 0x${(codeBase + e.value * 4).toRadixString(16)}');
  }
  for (var i = 0; i < program.words.length; i++) {
    print('MIPS 0x${(codeBase + i * 4).toRadixString(16)}: '
          '${program.words[i].toRadixString(16).padLeft(8, '0')}');
  }

  final interpretedBus = Ps2Bus();
  final interpreted = R5900(interpretedBus);
  load(interpreted, interpretedBus, program.words);
  for (var guard = 0; interpreted.pc != done && guard < 10000; guard++) {
    if (!interpreted.step()) throw StateError('interpreter failed at 0x${interpreted.pc.toRadixString(16)}');
  }
  if (interpreted.pc != done) throw StateError('interpreter timed out');
  final reference = results(interpretedBus);
  if (reference.join(',') != expected().join(',')) {
    throw StateError('interpreter disagrees with FizzBuzz: $reference');
  }
  print('INTERPRETER clocks=${interpreted.clocks}');
  print('INTERPRETER_OUTPUT ${asFizzBuzz(reference)}');

  final jit = Ps2Jit.create(native: true, compileThreshold: 1);
  if (jit == null) throw StateError('native x64 JIT unavailable');
  try {
    final nativeBus = Ps2Bus(ram: jit.ram);
    final cpu = R5900(nativeBus, gpr: jit.gpr);
    jit.attach(cpu);
    load(cpu, nativeBus, program.words);
    var compiledClocks = 0;
    var jitCalls = 0;
    var fallback = 0;
    for (var guard = 0; cpu.pc != done && guard < 10000; guard++) {
      final before = cpu.clocks;
      if (jit.run(64)) {
        compiledClocks += cpu.clocks - before;
        jitCalls++;
      } else {
        if (!cpu.step()) throw StateError('JIT fallback failed at 0x${cpu.pc.toRadixString(16)}');
        fallback++;
      }
    }
    if (cpu.pc != done) throw StateError('JIT timed out at 0x${cpu.pc.toRadixString(16)}');
    final actual = results(nativeBus);
    if (actual.join(',') != reference.join(',')) {
      throw StateError('JIT mismatch: $actual vs $reference');
    }
    if (compiledClocks <= 0) throw StateError('native JIT never executed guest instructions');
    print('NATIVE_JIT clocks=${cpu.clocks} compiledClocks=$compiledClocks jitCalls=$jitCalls fallbackInstructions=$fallback');
    print('NATIVE_JIT_OUTPUT ${asFizzBuzz(actual)}');
    print('NATIVE_JIT_MATCH true');
  } finally {
    jit.dispose();
  }

  // Recompile precisely the same IR with the same production x64 backend,
  // using deterministic stand-in host addresses for standalone disassembly.
  dumpX64(program);
}
