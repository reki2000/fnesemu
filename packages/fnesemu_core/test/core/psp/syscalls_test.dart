import 'package:fnesemu_core/src/core/psp/allegrex.dart';
import 'package:fnesemu_core/src/core/psp/elf.dart';
import 'package:fnesemu_core/src/core/psp/kernel.dart';
import 'package:fnesemu_core/src/core/psp/memory.dart';
import 'package:fnesemu_core/src/pad_source.dart';
import 'package:fnesemu_core/src/util/state.dart';
import 'package:test/test.dart';

import 'fixture.dart';

const _suspendIntr = 0x092968f4;
const _resumeIntr = 0x5f10d406;
const _setSdk = 0x7591c7db;
const _getSdk = 0xfc114573;
const _setCompiler = 0xf77d77cb;
const _printf = 0x13a5abef;
const _moduleId = 0xf0a26395;
const _moduleByAddress = 0xd8b73127;
const _displayFps = 0xdba6c4c4;
const _createThread = 0x446d8de6;
const _startThread = 0xf475845d;
const _allocBlock = 0x237dbd4f;
const _createFpl = 0xc07bb470;
const _deleteFpl = 0xed1410e0;
const _allocateFpl = 0xd979e9bf;
const _tryAllocateFpl = 0x623ae665;
const _freeFpl = 0xf6414a71;
const _registerSubIntr = 0xca04a2b9;
const _enableSubIntr = 0xfb8e22ec;
const _lockVolatile = 0x3e0271d3;

void main() {
  late PspMemory mem;
  late Allegrex cpu;
  late PspKernel kernel;
  late PspModuleImage image;
  final codes = <int, int>{};

  setUp(() {
    final (rom, _) = buildTestElf(code: [
      0
    ], imports: const [
      ('Kernel_Library', [_suspendIntr, _resumeIntr]),
      (
        'SysMemUserForUser',
        [_setSdk, _getSdk, _setCompiler, _printf, _allocBlock]
      ),
      ('ModuleMgrForUser', [_moduleId, _moduleByAddress]),
      ('sceDisplay', [_displayFps]),
      ('InterruptManager', [_registerSubIntr, _enableSubIntr]),
      ('sceSuspendForUser', [_lockVolatile]),
      (
        'ThreadManForUser',
        [
          _createThread,
          _startThread,
          _createFpl,
          _deleteFpl,
          _allocateFpl,
          _tryAllocateFpl,
          _freeFpl
        ]
      ),
    ]);
    mem = PspMemory();
    image = PspElf.load(mem, rom);
    kernel = PspKernel(mem, PadPort(), 0x09d98100);
    cpu = Allegrex(mem)..copyFrom(kernel.startModule(image).state);
    for (final import in image.imports) {
      codes[import.nid] = import.code;
    }
  });

  int call(int nid, [List<int> args = const []]) {
    cpu.r.setAll(4, args);
    kernel.dispatch(cpu, codes[nid]!);
    return cpu.r[2];
  }

  test('queries module identity and returns the display rate in f0', () {
    final id = call(_moduleId);
    expect(id, greaterThan(0));
    expect(call(_moduleByAddress, [image.entry]), id);
    expect(call(_moduleByAddress, [image.entry | 0x40000000]), id);
    expect(call(_moduleByAddress, [image.end]).toUnsigned(32), 0x8002012e);
    call(_displayFps);
    expect(cpu.f[0], 60.0);
    expect(kernel.unknownCalls, isEmpty);
  });

  test('k0 of a thread points at the cleared top of its stack', () {
    final main = kernel.current!;
    expect(main.state.r[26], main.stackTop - 0x100);
    final id = call(_createThread, [0, image.entry, 32, 0x10000]);
    final thread = kernel.threads[id]!;
    mem.write32(thread.stackTop - 0x100 + 4, 0x12345678);
    expect(call(_startThread, [id, 0, 0]), 0);
    expect(thread.state.r[26], thread.stackTop - 0x100);
    expect(mem.read32(thread.stackTop - 0x100 + 4), 0);
  });

  test('a fixed-size pool hands out and takes back its blocks', () {
    const out = 0x09000000;
    // two blocks of 6 bytes, rounded up to a word each
    final pool = call(_createFpl, [0, 2, 0, 6, 2, 0]);
    expect(pool, greaterThan(0));
    expect(call(_allocateFpl, [pool, out, 0]), 0);
    final first = mem.read32(out);
    expect(call(_tryAllocateFpl, [pool, out + 4]), 0);
    expect(mem.read32(out + 4), first + 8);
    expect(call(_tryAllocateFpl, [pool, out + 8]).toUnsigned(32), 0x800200d9);
    expect(call(_freeFpl, [pool, first + 4]), isNot(0));
    expect(call(_freeFpl, [pool, first]), 0);
    expect(call(_tryAllocateFpl, [pool, out + 8]), 0);
    expect(mem.read32(out + 8), first);
    expect(call(_deleteFpl, [pool]), 0);
    expect(call(_allocateFpl, [pool, out, 0]), isNot(0));
    expect(kernel.unknownCalls, isEmpty);
  });

  test('remembers version metadata and drains deferred GE callbacks on resume',
      () {
    expect(call(_setSdk, [0x02000010]), 0);
    expect(call(_setCompiler, [0x00030303]), 0);
    final enabled = call(_suspendIntr);
    final disabled = call(_suspendIntr);
    expect(enabled, 1);
    expect(disabled, 0);
    const callback = 0x08900000, result = 0x08900010;
    mem.write32(callback, 0xaca40000); // sw a0, 0(a1)
    mem.write32(callback + 4, 0x03e00008); // jr ra
    mem.write32(callback + 8, 0);
    kernel.ge.callbackRunner!(cpu, callback, 42, result);

    final writer = StateWriter('psp', 7, 0);
    kernel.saveState(writer, cpu);
    final reader = StateReader(writer.take(), 'psp', 7, 0);
    kernel = PspKernel(mem, PadPort(), image.end)..startModule(image);
    kernel.loadState(reader);
    reader.end();

    expect(call(_getSdk), 0x02000010);
    call(_resumeIntr, [disabled]);
    expect(mem.read32(result), 0);
    call(_resumeIntr, [enabled]);
    expect(mem.read32(result), 42);
    expect(kernel.unknownCalls, isEmpty);
  });

  test('an enabled vblank handler runs on each vblank and survives a save',
      () {
    const handler = 0x08900000, counter = 0x08900020;
    mem.write32(handler, 0x8ca20000); // lw v0, 0(a1)
    mem.write32(handler + 4, 0x24420001); // addiu v0, v0, 1
    mem.write32(handler + 8, 0x03e00008); // jr ra
    mem.write32(handler + 12, 0xaca20000); // sw v0, 0(a1)
    expect(call(_registerSubIntr, [30, 2, handler, counter]), 0);
    kernel.onVblank(cpu);
    expect(mem.read32(counter), 0, reason: 'not enabled yet');
    expect(call(_enableSubIntr, [30, 2]), 0);
    expect(call(_enableSubIntr, [30, 3]).toUnsigned(32), isNonZero);

    final writer = StateWriter('psp', 7, 0);
    kernel.saveState(writer, cpu);
    final reader = StateReader(writer.take(), 'psp', 7, 0);
    kernel = PspKernel(mem, PadPort(), image.end)..startModule(image);
    kernel.loadState(reader);
    reader.end();

    final pc = cpu.pc;
    kernel.onVblank(cpu);
    kernel.onVblank(cpu);
    expect(mem.read32(counter), 2);
    expect(cpu.pc, pc);
  });

  test('the volatile memory lock reports its area', () {
    const out = 0x08900040;
    expect(call(_lockVolatile, [0, out, out + 4]), 0);
    expect(mem.read32(out), 0x08400000);
    expect(mem.read32(out + 4), 0x400000);
  });

  test('formats debug output from registers and overflow arguments', () {
    const format = 0x08900000, name = 0x08900080;
    mem.writeBytes(format, [...'%-5s %+d %08X %llu %u %c %d %%'.codeUnits, 0]);
    mem.writeBytes(name, [...'PSP'.codeUnits, 0]);
    mem.write32(cpu.r[29], 65);
    mem.write32(cpu.r[29] + 4, -13);
    call(_printf, [format, name, 7, 0x1a2b, -1, 1, 9, 65]);
    // The seventh variadic argument is the first word passed on the stack.
    expect(kernel.log.toString(), 'PSP   +7 00001A2B 8589934591 9 A 65 %');
    expect(kernel.unknownCalls, isEmpty);
  });

  test('a large module leaves room for a worker stack and libc heap', () {
    expect(call(_createThread, [0, image.entry, 32, 0x40000]), greaterThan(0));
    expect(call(_allocBlock, [2, 0, 0, 0x180000]), greaterThan(0));
  });
}
