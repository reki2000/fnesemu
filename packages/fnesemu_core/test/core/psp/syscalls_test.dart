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
const _referThreadStatus = 0x17c1684e;
const _allocBlock = 0x237dbd4f;
const _createFpl = 0xc07bb470;
const _deleteFpl = 0xed1410e0;
const _allocateFpl = 0xd979e9bf;
const _tryAllocateFpl = 0x623ae665;
const _freeFpl = 0xf6414a71;
const _registerSubIntr = 0xca04a2b9;
const _enableSubIntr = 0xfb8e22ec;
const _lockVolatile = 0x3e0271d3;
const _setFrameBuf = 0x289d82fe;
const _getFrameBuf = 0xeeda2e54;
const _createEventFlag = 0x55c20a00;
const _setEventFlag = 0x1fb15a32;
const _clearEventFlag = 0x812346e4;
const _pollEventFlag = 0x30fd48f0;
const _referEventFlagStatus = 0xa66b0120;
const _sleepThread = 0x9ace131e;
const _wakeupThread = 0xd59ead2f;
const _createMbx = 0x8125221d;
const _sendMbx = 0xe9b3061e;
const _pollMbx = 0x0d81716a;
const _releaseWaitThread = 0x2c34e053;
const _getSystemParamInt = 0xa5da2406;
const _getSystemParamString = 0x34b78343;
const _getLanguageMode = 0x36aa6e91;
const _ioOpen = 0x109f50bc;
const _ioRead = 0x6a638d83;
const _ioWrite = 0x42ec03ac;
const _ioLseek32 = 0x68963324;
const _ioCloseAsync = 0xff5940b6;
const _ioWaitAsync = 0xe23eec33;

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
      ('sceDisplay', [_displayFps, _setFrameBuf, _getFrameBuf]),
      ('InterruptManager', [_registerSubIntr, _enableSubIntr]),
      ('sceSuspendForUser', [_lockVolatile]),
      ('sceUtility', [_getSystemParamInt, _getSystemParamString]),
      ('sceImpose', [_getLanguageMode]),
      ('IoFileMgrForUser', [
        _ioOpen, _ioRead, _ioWrite, _ioLseek32, _ioCloseAsync, _ioWaitAsync,
      ]),
      (
        'ThreadManForUser',
        [
          _createThread,
          _startThread,
          _referThreadStatus,
          _createFpl,
          _deleteFpl,
          _allocateFpl,
          _tryAllocateFpl,
          _freeFpl,
          _createEventFlag,
          _setEventFlag,
          _clearEventFlag,
          _pollEventFlag,
          _referEventFlagStatus,
          _sleepThread,
          _wakeupThread,
          _releaseWaitThread,
          _createMbx,
          _sendMbx,
          _pollMbx,
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

  test('the frame buffer query writes each value to its own pointer', () {
    expect(call(_setFrameBuf, [0x04000000, 512, 3, 1]), 0);
    const at = 0x09000000;
    for (var i = 0; i < 16; i += 4) {
      mem.write32(at + i, 0xdeadbeef);
    }
    expect(call(_getFrameBuf, [at, at + 8, at + 4, 1]), 0);
    expect(mem.read32(at) & 0x1fffffff, 0x04000000);
    expect(mem.read32(at + 4), 3);
    expect(mem.read32(at + 8), 512);
    expect(mem.read32(at + 12), 0xdeadbeef);
  });

  test('an event flag poll matches all or any bits and clears them', () {
    const out = 0x09000000;
    final flag = call(_createEventFlag, [0, 0, 0x5, 0]);
    expect(flag, greaterThan(0));
    // all of 0x7 is not set yet; any of it is
    expect(call(_pollEventFlag, [flag, 0x7, 0, out]).toUnsigned(32),
        0x800201af);
    expect(call(_pollEventFlag, [flag, 0x6, 1 | 0x20, out]), 0);
    expect(mem.read32(out), 0x5);
    // the any-bit wait cleared the waited bits 0x6, leaving 0x1
    expect(call(_setEventFlag, [flag, 0x10]), 0);
    expect(call(_pollEventFlag, [flag, 0x11, 0 | 0x10, out]), 0);
    expect(mem.read32(out), 0x11);
    expect(call(_pollEventFlag, [flag, 0x1, 1, out]).toUnsigned(32),
        0x800201af);
    expect(call(_setEventFlag, [flag, 0xff]), 0);
    expect(call(_clearEventFlag, [flag, 0x0f]), 0);
    expect(call(_pollEventFlag, [flag, 0xf0, 1, out]).toUnsigned(32),
        0x800201af);
    expect(call(_pollEventFlag, [flag, 0x0f, 0, out]), 0);
    expect(kernel.unknownCalls, isEmpty);
  });

  test('the status of an event flag shows its attributes and pattern', () {
    final flag = call(_createEventFlag, [0, 0x200, 0x5, 0]);
    expect(call(_setEventFlag, [flag, 0x30]), 0);
    const info = 0x09000000;
    expect(call(_referEventFlagStatus, [flag, info]), 0);
    expect(mem.read32(info + 36), 0x200);
    expect(mem.read32(info + 44), 0x35);
    expect(mem.read32(info + 48), 0);
    expect(call(_referEventFlagStatus, [flag + 99, info]).toUnsigned(32),
        0x800201a9);
    expect(kernel.unknownCalls, isEmpty);
  });

  test('a wake-up before the sleep lets the sleep return at once', () {
    final main = kernel.current!;
    expect(call(_wakeupThread, [main.id]), 0);
    expect(call(_sleepThread), 0);
    expect(main.status, PspThreadStatus.running);
  });

  test('the system settings are those of a Japanese console', () {
    const at = 0x09000000;
    expect(call(_getSystemParamInt, [8, at]), 0);
    expect(mem.read32(at), 0); // Japanese
    expect(call(_getSystemParamInt, [9, at]), 0);
    expect(mem.read32(at), 0); // the circle button confirms
    expect(call(_getSystemParamInt, [99, at]).toUnsigned(32), 0x80110103);
    mem.write32(at, 5);
    mem.write32(at + 4, 5);
    expect(call(_getLanguageMode, [at, at + 4]), 0);
    expect([mem.read32(at), mem.read32(at + 4)], [0, 0]);
    expect(call(_getSystemParamString, [1, at, 8]), 0);
    expect(mem.read32(at), 0x59414c50); // "PLAY"
    expect(kernel.unknownCalls, isEmpty);
  });

  test('a released wait returns an error to the waiting thread', () {
    final id = call(_createThread, [0, image.entry, 32, 0x10000]);
    expect(call(_releaseWaitThread, [id]).toUnsigned(32), 0x800201a4);
    final thread = kernel.threads[id]!..status = PspThreadStatus.waitSleep;
    expect(call(_releaseWaitThread, [id]), 0);
    expect(thread.status, PspThreadStatus.ready);
    expect(thread.pendingResult, 0x800201aa);
    expect(call(_releaseWaitThread, [id]).toUnsigned(32), 0x800201a4);
    expect(call(_releaseWaitThread, [kernel.current!.id]).toUnsigned(32),
        0x80020198);
  });

  test('a created thread that has not started reports the dormant status',
      () {
    const info = 0x09000000;
    final id = call(_createThread, [0, image.entry, 32, 0x10000]);
    expect(call(_referThreadStatus, [id, info]), 0);
    expect(mem.read32(info + 40), 0x10);
    expect(call(_startThread, [id, 0, 0]), 0);
    expect(call(_referThreadStatus, [id, info]), 0);
    expect(mem.read32(info + 40), isNot(0x10));
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

    final writer = StateWriter('psp', 9, 0);
    kernel.saveState(writer, cpu);
    final reader = StateReader(writer.take(), 'psp', 9, 0);
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

  test('an asynchronous close leaves its result to wait for', () {
    const path = 0x08900000, result = 0x08900040;
    const text = 'ms0:/C.BIN';
    for (var i = 0; i < text.length; i++) {
      mem.write8(path + i, text.codeUnitAt(i));
    }
    mem.write8(path + text.length, 0);
    final fd = call(_ioOpen, [path, 0x0603, 0x1ff]);
    mem.write32(result, 0xdeadbeef);
    expect(call(_ioCloseAsync, [fd]), 0);
    expect(call(_ioWaitAsync, [fd, result]), 0);
    expect(mem.read32(result), 0);
    expect(call(_ioWaitAsync, [fd, result]).toUnsigned(32), 0x80010009);
  });

  test('a message box keeps its messages across a save', () {
    const out = 0x09000000;
    final mbx = call(_createMbx, [0, 0, 0, 0]);
    expect(call(_sendMbx, [mbx, 0x08901230]), 0);
    final writer = StateWriter('psp', 9, 0);
    kernel.saveState(writer, cpu);
    final reader = StateReader(writer.take(), 'psp', 9, 0);
    kernel = PspKernel(mem, PadPort(), image.end)..startModule(image);
    kernel.loadState(reader);
    reader.end();
    expect(call(_pollMbx, [mbx, out]), 0);
    expect(mem.read32(out), 0x08901230);
    expect(call(_pollMbx, [mbx, out]).toUnsigned(32), 0x800201ca);
  });

  test('open files keep their contents and positions across a save', () {
    const path = 0x08900000, other = 0x08900040, buffer = 0x08900080;
    void putString(int at, String text) {
      for (var i = 0; i < text.length; i++) {
        mem.write8(at + i, text.codeUnitAt(i));
      }
      mem.write8(at + text.length, 0);
    }

    putString(path, 'ms0:/A.BIN');
    putString(other, 'host0:/log.txt');
    for (var i = 0; i < 4; i++) {
      mem.write8(buffer + i, 0x41 + i);
    }
    final stick = kernel.memStick;
    // write, create and truncate
    final fd = call(_ioOpen, [path, 0x0603, 0x1ff]);
    expect(call(_ioWrite, [fd, buffer, 4]), 4);
    expect(call(_ioLseek32, [fd, 1, 0]), 1);
    final log = call(_ioOpen, [other, 0x0603, 0x1ff]);
    expect(call(_ioWrite, [log, buffer, 2]), 2);

    final writer = StateWriter('psp', 9, 0);
    kernel.saveState(writer, cpu);
    final reader = StateReader(writer.take(), 'psp', 9, 0);
    kernel = PspKernel(mem, PadPort(), image.end)
      ..memStick = stick
      ..startModule(image);
    kernel.loadState(reader);
    reader.end();

    expect(call(_ioRead, [fd, buffer + 0x10, 8]), 3);
    expect([for (var i = 0; i < 3; i++) mem.read8(buffer + 0x10 + i)],
        [0x42, 0x43, 0x44]);
    expect(call(_ioLseek32, [log, 0, 0]), 0);
    expect(call(_ioRead, [log, buffer + 0x20, 8]), 2);
    expect(mem.read8(buffer + 0x21), 0x42);
    // a file opened after the load takes a new descriptor
    expect(call(_ioOpen, [other, 0x0603, 0x1ff]), greaterThan(log));
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

    final writer = StateWriter('psp', 9, 0);
    kernel.saveState(writer, cpu);
    final reader = StateReader(writer.take(), 'psp', 9, 0);
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
