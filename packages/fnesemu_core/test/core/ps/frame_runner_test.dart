import 'package:fnesemu_core/src/core/ps/ps.dart';
import 'package:fnesemu_core/src/sram.dart';
import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

Ps createCore(int startClock, {bool jit = false}) {
  final core = Ps(jit: jit)..setSram(Sram());
  addTearDown(core.dispose);
  core.reset();
  core.cpu.pc = 0;
  core.cpu.nextPc = 4;
  core.cpu.r[1] = 0x1f8010e8;
  core.cpu.r[2] = 0x11000000;
  core.cpu.r[5] = 0x10000;
  core.bus.mem32[0x10000 >> 2] = 0x12345678;
  core.dma.channels[6].startAddr = 0x10000;
  core.dma.channels[6].blockCtrl = 2;
  core.dma.control = 0x08000000;
  core.dma.setInterrupt(2, 0xc0);
  final completionClock = ((startClock + 23) ~/ 24) * 24 + 2;
  if (startClock > 0) {
    final before = completionClock - 2 == startClock
        ? startClock - 2
        : completionClock - 2;
    core.bus.mem32[before ~/ 2] = 0x8ca30000; // lw r3, 0(r5)
  }
  core.bus.mem32[startClock ~/ 2] = 0xac220000; // sw r2, 0(r1)
  core.bus.mem32[completionClock ~/ 2] = 0x8ca40000; // lw r4, 0(r5)
  return core;
}

void main() {
  for (final startClock in [0, 22, 24, 60, 98, 102]) {
    test('JIT returns to DMA scheduler after wake at clock $startClock', () {
      if (!JitRuntime.nativeSupported) {
        markTestSkipped('no native recompiler on this host');
        return;
      }
      final core = createCore(startClock, jit: true);
      expect(core.jit, isNotNull);
      core.dma.exec(24);
      core.jit!.run(500);
      expect(core.cpu.clocks, startClock + 2);
      expect(core.cpu.r[4], 0);
      core.runFrame(2);
      expect(core.bus.mem32[0xfffc >> 2], 0xffffff);
      expect(core.dma.active, isFalse);
      expect(core.bus.interrupt.status & 8, 8);
    });
  }
  test('a suspended JIT runs frames with the interpreter', () {
    if (!JitRuntime.nativeSupported) {
      markTestSkipped('no native recompiler on this host');
      return;
    }
    final reference = createCore(24);
    final suspended = createCore(24, jit: true)..jitSuspended = true;
    expect(suspended.jitSuspended, isTrue);
    reference.runFrame(2);
    suspended.runFrame(2);
    expect(suspended.jitClocks, 0);
    expect(suspended.cpu.clocks, reference.cpu.clocks);
    expect(suspended.cpu.r.toList(), reference.cpu.r.toList());
    expect(suspended.bus.mem32, reference.bus.mem32);
  });
  for (final startClock in [0, 2, 22, 24, 26, 46, 48, 50, 60, 98, 100, 102]) {
    test('frame runner preserves DMA wake timing at clock $startClock', () {
      final reference = createCore(startClock);
      final batched = createCore(startClock);
      var lines = 0;
      while (lines < 2) {
        if (reference.exec(true).scanlineRendered) lines++;
      }
      batched.runFrame(2);
      if (startClock > 0) expect(batched.cpu.r[3], 0x12345678);
      expect(batched.cpu.r[4], 0xfffc);
      expect(batched.bus.mem32[0xfffc >> 2], 0xffffff);
      expect(batched.bus.interrupt.status & 8, 8);
      expect(batched.dump(), reference.dump());
      expect(batched.bus.mem, reference.bus.mem);
    });
  }
  test('enabling a pending channel preserves DMA wake timing', () {
    final core = createCore(60);
    core.dma.control = 0;
    core.dma.setChannelCtrl(6, 0x11000000);
    core.cpu.r[1] = 0x1f8010f0;
    core.cpu.r[2] = 0x08000000;
    core.runFrame(2);
    expect(core.cpu.r[3], 0x12345678);
    expect(core.cpu.r[4], 0xfffc);
    expect(core.bus.interrupt.status & 8, 8);
  });

  test('DMA can wake again after completing a frame transfer', () {
    final core = createCore(60);
    core.runFrame(2);
    expect(core.dma.active, isFalse);
    core.dma.channels[6].startAddr = 0x10004;
    core.dma.channels[6].blockCtrl = 2;
    core.dma.setChannelCtrl(6, 0x11000000);
    core.runFrame(1);
    expect(core.bus.mem32[0x10004 >> 2], 0x10000);
    expect(core.bus.mem32[0x10000 >> 2], 0xffffff);
    expect(core.dma.active, isFalse);
  });
}
