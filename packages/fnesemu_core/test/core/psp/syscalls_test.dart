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
const _allocBlock = 0x237dbd4f;

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
      ('ThreadManForUser', [_createThread]),
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

    final writer = StateWriter('psp', 6, 0);
    kernel.saveState(writer, cpu);
    final reader = StateReader(writer.take(), 'psp', 6, 0);
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
