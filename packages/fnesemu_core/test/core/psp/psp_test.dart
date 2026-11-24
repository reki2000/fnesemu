import 'dart:typed_data';

import 'package:fnesemu_core/core_factory.dart';
import 'package:fnesemu_core/src/core/psp/memory.dart';
import 'package:fnesemu_core/src/core/psp/psp.dart';
import 'package:fnesemu_core/src/pad_button.dart';
import 'package:fnesemu_core/src/pad_source.dart';
import 'package:fnesemu_core/src/types.dart';
import 'package:test/test.dart';

import 'fixture.dart';

const _nidSetFrameBuf = 0x289d82fe;
const _nidWaitVblank = 0x984c27e7;
const _nidCreateThread = 0x446d8de6;
const _nidStartThread = 0xf475845d;
const _nidWaitThreadEnd = 0x278c0df5;
const _nidDelayThread = 0xceadeb47;
const _nidReadCtrl = 0x1f803938;
const _nidExitGame = 0x05572a5f;

const _imports = [
  ('sceDisplay', [_nidSetFrameBuf, _nidWaitVblank]),
  (
    'ThreadManForUser',
    [_nidCreateThread, _nidStartThread, _nidWaitThreadEnd, _nidDelayThread]
  ),
  ('sceCtrl', [_nidReadCtrl]),
  ('LoadExecForUser', [_nidExitGame]),
];

/// A small homebrew program: it presents a frame buffer, waits for the
/// refresh, samples the controller, then runs a worker thread that writes
/// results around a delay, and exits after joining it. Stub addresses
/// depend on the code size, so the program is assembled twice: a probe
/// pass yields the layout, the second pass calls the real stubs.
Uint8List buildProgram({int workerDelay = 1000, bool spinWhileWaiting = false}) {
  List<int> assemble(Map<String, int> stubs) {
    int stub(String lib, int nid) => stubs['$lib/$nid'] ?? 0;
    final a = Asm(0x08800000);
    a.li(Reg.t0, 0x44000000);
    a.li(Reg.t1, 0x11223344);
    a.sw(Reg.t1, 0, Reg.t0);
    a.li(Reg.t1, 0x55667788);
    a.sw(Reg.t1, 4, Reg.t0);
    a.li(Reg.a0, 0x44000000);
    a.li(Reg.a1, 512);
    a.li(Reg.a2, 3);
    a.li(Reg.a3, 0);
    a.jal(stub('sceDisplay', _nidSetFrameBuf));
    a.nop();
    a.jal(stub('sceDisplay', _nidWaitVblank));
    a.nop();
    a.li(Reg.a0, 0x08900010);
    a.jal(stub('sceCtrl', _nidReadCtrl));
    a.nop();
    // The worker thread's name, written as bytes into free memory.
    a.li(Reg.t0, 0x08900020);
    a.li(Reg.t1, 0x6b726f77); // 'work'
    a.sw(Reg.t1, 0, Reg.t0);
    a.li(Reg.t1, 0x00007265); // 'er'
    a.sw(Reg.t1, 4, Reg.t0);
    a.li(Reg.a0, 0x08900020);
    a.liAbs(Reg.a1, 'worker');
    a.li(Reg.a2, spinWhileWaiting ? 0x10 : 0x30);
    a.li(Reg.a3, 0x8000);
    a.jal(stub('ThreadManForUser', _nidCreateThread));
    a.nop();
    a.addiu(Reg.s0, Reg.v0, 0);
    a.addiu(Reg.a0, Reg.s0, 0);
    a.li(Reg.a1, 0);
    a.li(Reg.a2, 0);
    a.jal(stub('ThreadManForUser', _nidStartThread));
    a.nop();
    if (spinWhileWaiting) {
      a.li(Reg.a0, 1);
      a.jal(stub('ThreadManForUser', _nidDelayThread));
      a.nop();
      a.li(Reg.t0, 0x08900000);
      a.label('waitForWorker');
      a.lw(Reg.t1, 8, Reg.t0);
      a.beq(Reg.t1, Reg.zero, 'waitForWorker');
      a.addiu(Reg.s2, Reg.s2, 1);
    }
    a.addiu(Reg.a0, Reg.s0, 0);
    a.li(Reg.a1, 0);
    a.jal(stub('ThreadManForUser', _nidWaitThreadEnd));
    a.nop();
    a.li(Reg.t0, 0x08900000);
    a.lw(Reg.t1, 0, Reg.t0);
    a.sw(Reg.t1, 4, Reg.t0);
    a.jal(stub('LoadExecForUser', _nidExitGame));
    a.nop();
    a.label('worker');
    a.addiu(Reg.s1, Reg.ra, 0); // the entry link, kept across the call
    a.li(Reg.t0, 0x08900000);
    a.li(Reg.t1, 0xcafebabe);
    a.sw(Reg.t1, 0, Reg.t0);
    a.li(Reg.a0, workerDelay);
    a.jal(stub('ThreadManForUser', _nidDelayThread));
    a.nop();
    a.li(Reg.t1, 0x0d15ea5e);
    a.sw(Reg.t1, 8, Reg.t0);
    a.jr(Reg.s1);
    a.nop();
    return a.finish();
  }

  final (_, probe) = buildTestElf(code: assemble(const {}), imports: _imports);
  final (bytes, _) =
      buildTestElf(code: assemble(probe.stubOf), imports: _imports);
  return bytes;
}

void main() {
  test('video memory repeats every 2 MiB', () {
    final mem = PspMemory();
    mem.write16(0x04088000, 0x1234);
    expect(mem.read16(0x04288000), 0x1234);
    expect(mem.read16(0x04688000), 0x1234);
    expect(mem.read16(0x04888000), 0);
  });

  test('the factory resolves the psp core and its files', () {
    expect(CoreFactory.system('psp').id, 'psp');
    expect(CoreFactory.of('psp'), isA<Psp>());
    final bytes = buildProgram();
    expect(CoreFactory.findRom('game.elf', bytes)?.id, 'psp');
    expect(CoreFactory.findRom('game.xyz', bytes), isNull);
    // A MIPS ELF without the module info section stays with the ps2 core.
    final plain = Uint8List(52);
    plain[0] = 0x7f;
    plain[1] = 0x45;
    plain[2] = 0x4c;
    plain[3] = 0x46;
    expect(CoreFactory.findRom('game.elf', plain)?.id, 'ps2');
    final core = Psp();
    addTearDown(core.dispose);
    expect(core.buttons.length, 20);
    expect(core.axes, [PadAxis.leftX, PadAxis.leftY]);
  });

  test('instruction stepping preserves the scanline deadline', () {
    final a = Asm(0x08800000);
    a.nop();
    a.j(2, 0x08800004);
    a.nop();
    final (rom, _) = buildTestElf(code: a.finish());
    final core = Psp()..setRom(rom);
    addTearDown(core.dispose);
    final pc = core.cpu.pc;
    final step = core.exec(true);
    expect(step.elapsedClocks, 1);
    expect(step.scanlineRendered, isFalse);
    expect(core.cpu.pc, pc + 4);
    final line = core.exec(false);
    expect(line.scanlineRendered, isTrue);
    expect(line.elapsedClocks, core.clocksInScanline);
  });

  test('a saved delay wakes after the 32-bit clock range', () {
    final rom = buildProgram(workerDelay: 22000000);
    final core = Psp()..setRom(rom);
    addTearDown(core.dispose);
    for (var frame = 0; frame < 1200; frame++) {
      expect(core.runFrame(core.scanlinesInFrame).stopped, isFalse);
    }
    expect(core.cpu.clocks, greaterThan(1 << 32));
    // Save before the second core: on the Web its JIT takes the memory.
    final state = core.saveState();
    final restored = Psp()..setRom(rom);
    addTearDown(restored.dispose);
    restored.loadState(state);
    expect(restored.cpu.clocks, core.cpu.clocks);
    for (var frame = 0; frame < 200; frame++) {
      if (restored.runFrame(restored.scanlinesInFrame).stopped) break;
    }
    expect(restored.mem.read32(0x08900008), 0x0d15ea5e);
  });

  group('homebrew run', () {
    late Psp core;
    late Uint8List rom;

    void load(Psp target) {
      final pad = PadState();
      pad.press(0, const PadButton('x'));
      target.input = pad;
      target.setRom(rom);
    }

    ExecResult runToEnd(Psp target) {
      var result = target.runFrame(286);
      var frames = 1;
      while (!result.stopped && frames < 300) {
        result = target.runFrame(286);
        frames++;
      }
      return result;
    }

    setUp(() {
      rom = buildProgram();
      core = Psp();
      addTearDown(core.dispose);
      load(core);
    });

    test('threads, display and controller work together', () {
      final result = runToEnd(core);
      expect(result.stopped, isTrue);
      expect(core.mem.read32(0x08900000), 0xcafebabe);
      expect(core.mem.read32(0x08900004), 0xcafebabe);
      expect(core.mem.read32(0x08900008), 0x0d15ea5e);
      expect(core.mem.read32(0x08900014) & 0x4000, 0x4000); // cross held
      final image = core.imageBuffer();
      expect(image.width, 480);
      expect(image.height, 272);
      // the display shows no alpha: the stored 0x11 and 0x55 read opaque
      expect(image.buffer[0], 0xff223344);
      expect(image.buffer[1], 0xff667788);
    });

    test('a saved state resumes to the same outcome', () {
      core.runFrame(286);
      final state = core.saveState();
      runToEnd(core);
      final first = [
        core.mem.read32(0x08900000),
        core.mem.read32(0x08900004),
        core.mem.read32(0x08900008),
      ];
      final other = Psp();
      addTearDown(other.dispose);
      load(other);
      other.loadState(state);
      final result = runToEnd(other);
      expect(result.stopped, isTrue);
      expect(other.mem.read32(0x08900000), first[0]);
      expect(other.mem.read32(0x08900004), first[1]);
      expect(other.mem.read32(0x08900008), first[2]);
    });

    test('a state of another medium is rejected', () {
      final state = core.saveState();
      final (otherRom, _) = buildTestElf(code: [0, 0, 0]);
      final other = Psp()..setRom(otherRom);
      addTearDown(other.dispose);
      expect(() => other.loadState(state), throwsA(anything));
    });
  });
}
