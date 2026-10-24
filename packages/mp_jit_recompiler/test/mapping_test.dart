import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

void main() {
  for (final native in [false, true]) {
    final name = native ? 'compiled' : 'reference';
    test('$name 1KiB mappings preserve boundaries and address aliases', () {
      final accesses = <int>[];
      int read(int addr, int size) {
        accesses.add(addr);
        return 0x76543210;
      }

      void write(int addr, int size, int value) => accesses.add(addr);
      final rt = native
          ? JitRuntime.native(
              ctxWords: 32,
              addrMask: 0x7fffffff,
              read: read,
              write: write,
              pageShift: 10)
          : JitRuntime.interpreter(
              ctxWords: 32,
              addrMask: 0x7fffffff,
              read: read,
              write: write,
              pageShift: 10);
      if (rt == null) {
        markTestSkipped('no compiled runtime on this host');
        return;
      }
      addTearDown(rt.dispose);
      final memory = rt.alloc(1024);
      rt.mapPages(0x1f800000, memory.length, memory);
      final b = IrBuilder(0x100);
      b.store(4, b.c32(0x1f8003fc), b.c32(0x89abcdef));
      b.ctxStore(8, b.load(4, b.c32(0x9f8003fc)));
      b.ctxStore(9, b.load(4, b.c32(0x1f800400)));
      b.ctxStore(10, b.load(4, b.c32(0xbf800000)));
      b.ctxStore(11, b.load(4, b.c32(0x5f800000)));
      rt.install(
          b.finish(const IrExitTerm(IrExit(JitReason.user, 0x104)), cost: 1));
      rt.ctx[JitCtx.budget] = 100;
      expect(rt.run(0x100, 0), JitReason.user);
      expect(rt.ctx[8], 0x89abcdef);
      expect(rt.ctx[9], 0x76543210);
      expect(rt.ctx[10], 0x76543210);
      expect(rt.ctx[11], 0x76543210);
      expect(accesses, [0x1f800400, 0xbf800000, 0x5f800000]);
      expect(rt.mappedWord(0x9f8003fc), 0x89abcdef);
      rt.unmapPages(0x1f800000, 1024);
      accesses.clear();
      rt.ctx[JitCtx.budget] = 100;
      rt.run(0x100, 0);
      expect(accesses.first, 0x1f8003fc);
      expect(rt.mappedWord(0x1f800000), isNull);
    });

    test('$name 1KiB code guards and mapped side exits use the selected size',
        () {
      final rt = native
          ? JitRuntime.native(
              ctxWords: 32,
              addrMask: 0xffff,
              read: (_, __) => 0,
              write: (_, __, ___) {},
              pageShift: 10)
          : JitRuntime.interpreter(
              ctxWords: 32,
              addrMask: 0xffff,
              read: (_, __) => 0,
              write: (_, __, ___) {},
              pageShift: 10);
      if (rt == null) {
        markTestSkipped('no compiled runtime on this host');
        return;
      }
      addTearDown(rt.dispose);
      final memory = rt.alloc(1024);
      rt.mapPages(0x1400, 1024, memory);
      final b = IrBuilder(0x100);
      b.guard(0x1400, 0);
      b.load(4, b.c32(0x1800),
          unmapped: const IrExit(JitReason.user + 1, 0x108));
      rt.install(b.finish(const IrJump(0x100), cost: 1));
      rt.ctx[JitCtx.budget] = 100;
      expect(rt.run(0x100, 0), JitReason.user + 1);
      expect(rt.ctx[JitCtx.faultAddr], 0x1800);
      memory[0] = 1;
      rt.ctx[JitCtx.budget] = 100;
      expect(rt.run(0x100, 0), JitReason.invalid);
    });
  }
}
