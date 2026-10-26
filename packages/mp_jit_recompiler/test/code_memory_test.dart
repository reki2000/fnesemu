import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

void main() {
  for (final native in [false, true]) {
    group(native ? 'native' : 'reference', () {
      late JitRuntime rt;
      late JitCodeMemory code;
      setUp(() {
        JitRuntime make() => native
            ? JitRuntime.native(
                ctxWords: 32,
                addrMask: 0xffff,
                read: (_, __) => 0,
                write: (_, __, ___) {})!
            : JitRuntime.interpreter(
                ctxWords: 32,
                addrMask: 0xffff,
                read: (_, __) => 0,
                write: (_, __, ___) {});
        rt = make();
        code = JitCodeMemory(rt);
      });
      tearDown(() => rt.dispose());

      int page(int addr) => addr >>> rt.pageShift;

      test('protection removes writes from every writable alias', () {
        final ram = rt.alloc(0x2000);
        code.map(0x1000, ram.length, ram);
        code.map(0x5000, ram.length, ram);
        code.map(0x9000, ram.length, ram, writable: false);
        expect(code.protect(0x6004), isTrue);
        for (final alias in [0x2000, 0x6000]) {
          expect(rt.writePages[page(alias)], isNull);
          expect(rt.readPages[page(alias)], isNotNull);
        }
        expect(rt.writePages[page(0x1000)], isNotNull);
        expect(rt.writePages[page(0x5000)], isNotNull);
        expect(code.isProtected(0x2000), isTrue);
        expect(code.isProtected(0xa000), isTrue);
        expect(code.isProtected(0x1000), isFalse);
        expect(code.protect(0xe000), isFalse);
      });

      test('store exits release a protected page at the limit', () {
        final ram = rt.alloc(0x2000);
        code.map(0x1000, ram.length, ram);
        code.map(0x5000, ram.length, ram);
        expect(code.noteStoreExit(0x2000), isFalse, reason: 'unprotected');
        code.protect(0x1000);
        for (var i = 1; i < 4; i++) {
          expect(code.noteStoreExit(0x5004, limit: 4), isFalse);
        }
        expect(code.noteStoreExit(0x1008, limit: 4), isTrue);
        expect(code.isReleased(0x5000), isTrue);
        expect(rt.writePages[page(0x1000)], isNotNull);
        expect(code.noteStoreExit(0x1000, limit: 4), isFalse);
        code.protect(0x2000);
        expect(code.noteStoreExit(0x2000, limit: 4), isFalse,
            reason: 'the count of another page starts again');
      });

      test('a compiled store to a protected alias leaves the block', () {
        final ram = rt.alloc(0x1000);
        code.map(0x1000, ram.length, ram);
        code.map(0x3000, ram.length, ram);
        code.protect(0x1000);
        final b = IrBuilder(0x100);
        b.store(4, b.c32(0x3010), b.c32(7),
            unmapped: const IrExit(JitReason.user + 1, 0x100, spent: 0));
        rt.install(b.finish(const IrExitTerm(IrExit(JitReason.user, 0x104)),
            cost: 1));
        rt.ctx[JitCtx.budget] = 10;
        expect(rt.run(0x100, 0), JitReason.user + 1);
        expect(rt.ctx[JitCtx.faultAddr], 0x3010);
        expect(ram[0x10], 0);
      });

      test('release drops recorded blocks and keeps the page writable', () {
        final ram = rt.alloc(0x1000);
        code.map(0x1000, ram.length, ram);
        code.map(0x3000, ram.length, ram);
        final b = IrBuilder(0x1000);
        rt.install(b.finish(const IrExitTerm(IrExit(JitReason.user, 0x1004)),
            cost: 1));
        code.protect(0x1000, block: (0x1000, 0));
        code.release(0x3000);
        expect(rt.contains(0x1000, 0), isFalse);
        expect(rt.writePages[page(0x1000)], isNotNull);
        expect(rt.writePages[page(0x3000)], isNotNull);
        expect(code.isReleased(0x1000), isTrue);
        expect(code.protect(0x1000), isFalse);
        expect(rt.writePages[page(0x1000)], isNotNull);
      });

      test('reset restores writes and forgets releases', () {
        final ram = rt.alloc(0x2000);
        code.map(0x1000, ram.length, ram);
        code.protect(0x1000);
        code.release(0x2000);
        code.reset();
        expect(rt.writePages[page(0x1000)], isNotNull);
        expect(code.isProtected(0x1000), isFalse);
        expect(code.isReleased(0x2000), isFalse);
        expect(code.protect(0x2000), isTrue);
        expect(rt.writePages[page(0x2000)], isNull);
      });
    },
        skip: native && !JitRuntime.nativeSupported
            ? 'No compiled backend'
            : false);
  }
}
