@TestOn('browser || node')
library;

import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

void main() {
  late JitRuntime rt;
  setUp(() {
    expect(JitRuntime.nativeSupported, isTrue,
        reason: 'Web tests must exercise compiled Wasm, not skip the backend');
    rt = JitRuntime.native(
        ctxWords: 32,
        addrMask: 0x1fffffff,
        read: (_, __) => 0,
        write: (_, __, ___) {})!;
  });
  tearDown(() => rt.dispose());

  test('Dart buffer views remain shared after allocations and cache clears',
      () {
    final ram = rt.alloc(4096);
    expect(ram.offsetInBytes, greaterThan(0));
    rt.mapPages(0x1000, ram.length, ram);
    final words = Uint32List.sublistView(ram);
    words[0] = 0x89abcdef;
    final b = IrBuilder(0x100);
    b.ctxStore(8, b.load(4, b.c32(0x1000)));
    b.store(4, b.c32(0x1004), b.ctxLoad(9));
    final block =
        b.finish(const IrExitTerm(IrExit(JitReason.user, 0x104)), cost: 1);
    for (int i = 0; i < 3; i++) {
      rt.alloc(1024 * 1024);
      rt.clear();
      expect(rt.contains(0x100, 0), isFalse);
      rt.install(block);
      expect(rt.contains(0x100, 0), isTrue);
      rt.ctx[9] = 0xfedcba98;
      rt.ctx[JitCtx.budget] = 100;
      expect(rt.run(0x100, 0), JitReason.user);
      expect(rt.ctx[8], 0x89abcdef);
      expect(words[1], 0xfedcba98);
    }
    expect(() => rt.alloc(64 << 20), throwsStateError);
    expect(words[1], 0xfedcba98);
  });

  test('allocation and cache zeroing preserve neighbouring guest memory', () {
    final first = rt.alloc(4096);
    first.fillRange(0, first.length, 0xa5);
    final second = rt.alloc(4096);
    expect(second, everyElement(0));
    second.fillRange(0, second.length, 0x5a);
    rt.ctx[8] = 0x12345678;
    final b = IrBuilder(0x100);
    rt.install(b.finish(const IrJump(0x104), cost: 1));
    rt.clear();
    expect(first, everyElement(0xa5));
    expect(second, everyElement(0x5a));
    expect(rt.ctx[8], 0x12345678);
    expect(rt.alloc(1), [0]);
    expect(first, everyElement(0xa5));
    expect(second, everyElement(0x5a));
  });

  test('table growth preserves static links and helpers preserve unsigned bits',
      () {
    final helper = rt.addHelper((a, b, c) {
      expect([a, b, c], [0xffffffff, 0x80000000, 0x12345678]);
      return 0x89abcdef;
    });
    for (int i = 0; i < 300; i++) {
      final b = IrBuilder(0x1000 + 4 * i);
      b.ctxStore(8, b.add(b.ctxLoad(8), b.c32(1)));
      if (i == 299) {
        b.ctxStore(
            9, b.call(helper, b.c32(-1), b.c32(0x80000000), b.c32(0x12345678)));
      }
      rt.install(b.finish(
          i == 299
              ? const IrExitTerm(IrExit(JitReason.user, 0x2000))
              : IrJump(0x1000 + 4 * (i + 1)),
          cost: 1));
    }
    rt.ctx[JitCtx.budget] = 1000;
    expect(rt.run(0x1000, 0), JitReason.user);
    expect(rt.ctx[8], 300);
    expect(rt.ctx[9], 0x89abcdef);
  });

  test('long guest loops use constant host stack space', () {
    final b = IrBuilder(0x100);
    b.ctxStore(8, b.add(b.ctxLoad(8), b.c32(1)));
    rt.install(b.finish(const IrJump(0x100), cost: 1));
    rt.ctx[JitCtx.budget] = 1000000;
    expect(rt.run(0x100, 0), JitReason.budget);
    expect(rt.ctx[8], 1000000);
  });

  test('cache eviction drops old links and permits recompilation', () {
    for (int i = 0; i < 4100; i++) {
      final b = IrBuilder(0x1000 + 4 * i);
      rt.install(b.finish(IrExitTerm(IrExit(JitReason.user, 0x1000 + 4 * i)),
          cost: 1));
    }
    expect(rt.contains(0x1000, 0), isFalse);
    rt.ctx[JitCtx.budget] = 100;
    expect(rt.run(0x1000 + 4 * 4099, 0), JitReason.user);
    expect(rt.run(0x1000, 0), JitReason.miss);
    rt.clear();
    final b = IrBuilder(0x1000);
    rt.install(
        b.finish(const IrExitTerm(IrExit(JitReason.user, 0x1004)), cost: 1));
    expect(rt.run(0x1000, 0), JitReason.user);
  });

  test('disposed runtimes return their shared linear memory', () {
    // Each runtime takes more than a fifth of the fixed linear memory.
    for (int i = 0; i < 12; i++) {
      final other = JitRuntime.native(
        ctxWords: 32,
        addrMask: 0x1fffffff,
        read: (_, __) => 0,
        write: (_, __, ___) {},
      )!;
      final ram = other.alloc(12 << 20);
      expect(ram.every((b) => b == 0), isTrue);
      ram.fillRange(0, ram.length, 0xff);
      other.dispose();
    }
  });
}
