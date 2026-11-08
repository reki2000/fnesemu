import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

void main() {
  for (final native in [false, true]) {
    final name = native ? 'compiled' : 'reference';

    JitRuntime? create(List<int> accesses) {
      int read(int addr, int size) {
        accesses.add(addr);
        return 0x5a5a5a5a;
      }

      void write(int addr, int size, int value) => accesses.add(addr);
      return native
          ? JitRuntime.native(
              ctxWords: 32,
              addrMask: 0x1fffffff,
              read: read,
              write: write,
            )
          : JitRuntime.interpreter(
              ctxWords: 32,
              addrMask: 0x1fffffff,
              read: read,
              write: write,
            );
    }

    test('$name translated accesses follow their tables', () {
      final accesses = <int>[];
      final rt = create(accesses);
      if (rt == null) {
        markTestSkipped('no compiled runtime on this host');
        return;
      }
      addTearDown(rt.dispose);
      final memory = rt.alloc(0x4000);
      rt.mapPages(0x0c000000, memory.length, memory);
      // P1-like addresses bypass the tables.
      final reads = rt.addTranslationTable(
        write: false,
        directStart: 0x80000000,
        directEnd: 0xc0000000,
      );
      final writes = rt.addTranslationTable(
        write: true,
        directStart: 0x80000000,
        directEnd: 0xc0000000,
      );
      const key = 0x801;
      rt.mapTranslation(reads, 0x00010000, key, 0x0c001000);
      rt.mapTranslation(writes, 0x00010000, key, 0x0c001000);
      rt.mapTranslation(reads, 0x00020000, key + 1, 0x0c002000);
      expect(rt.translate(reads, key, 0x00010ffc), 0x0c001ffc);
      expect(rt.translate(reads, key, 0x00020000), isNull);
      expect(rt.translate(reads, key, 0x8c003000), 0x8c003000);

      // ctx[1] is stored through the translation of ctx[0], then loaded
      // back through it and through the direct window at ctx[2].
      final b = IrBuilder(0x100);
      final exit = IrExit(JitReason.user + 1, 0x100, spent: 0);
      const r = IrTranslation(0, key), w = IrTranslation(1, key);
      b.store(4, b.ctxLoad(16), b.ctxLoad(17), unmapped: exit, translation: w);
      b.ctxStore(18, b.load(4, b.ctxLoad(16), unmapped: exit, translation: r));
      b.ctxStore(19, b.load(2, b.ctxLoad(20), unmapped: exit, translation: r));
      rt.install(
        b.finish(const IrExitTerm(IrExit(JitReason.user, 0x104)), cost: 1),
      );

      int run(int virtual, int value, int direct) {
        rt.ctx
          ..[16] = virtual
          ..[17] = value
          ..[20] = direct
          ..[18] = 0
          ..[19] = 0
          ..[JitCtx.budget] = 100;
        return rt.run(0x100, 0);
      }

      expect(run(0x00010010, 0x12345678, 0x8c001010), JitReason.user);
      expect(
        memory.buffer
            .asByteData(memory.offsetInBytes)
            .getUint32(0x1010, Endian.little),
        0x12345678,
      );
      expect(rt.ctx[18], 0x12345678);
      expect(rt.ctx[19], 0x5678);

      // Another key, or a slot of another page, misses with the virtual
      // address as the fault address.
      expect(run(0x00020010, 1, 0x8c001010), JitReason.user + 1);
      expect(rt.ctx[JitCtx.faultAddr], 0x00020010);
      expect(run(0x00410010, 1, 0x8c001010), JitReason.user + 1);
      expect(rt.ctx[JitCtx.faultAddr], 0x00410010);

      // Write-protecting the guest page empties the write slot only.
      rt.unmapPages(0x0c001000, 0x1000, read: false);
      expect(run(0x00010010, 2, 0x8c001010), JitReason.user + 1);
      expect(rt.translate(reads, key, 0x00010010), 0x0c001010);
      rt.mapPages(0x0c001000, 0x1000, memory, offset: 0x1000, read: false);
      expect(run(0x00010010, 2, 0x8c001010), JitReason.user + 1);
      rt.mapTranslation(writes, 0x00010000, key, 0x0c001000);
      expect(run(0x00010010, 3, 0x8c001010), JitReason.user);
      expect(rt.ctx[18], 3);

      // Moving the guest page moves the slot with it.
      rt.mapPages(0x0c001000, 0x1000, memory, offset: 0x3000);
      expect(run(0x00010020, 4, 0x8c003020), JitReason.user);
      expect(rt.ctx[19], 4);

      // Unmapping a virtual page, or the whole table, empties slots.
      rt.unmapTranslation(reads, 0x00011000);
      expect(rt.translate(reads, key, 0x00010000), isNotNull);
      rt.unmapTranslation(reads, 0x00010000);
      expect(run(0x00010020, 5, 0x8c003020), JitReason.user + 1);
      rt.mapTranslation(reads, 0x00010000, key, 0x0c001000);
      rt.clearTranslations(writes);
      expect(run(0x00010020, 6, 0x8c003020), JitReason.user + 1);
      expect(accesses, isEmpty);
    });

    test('$name keyed tables keep one page under each key', () {
      final rt = create([]);
      if (rt == null) {
        markTestSkipped('no compiled runtime on this host');
        return;
      }
      addTearDown(rt.dispose);
      final memory = rt.alloc(0x4000);
      rt.mapPages(0x0c000000, memory.length, memory);
      final data = memory.buffer.asByteData(memory.offsetInBytes);
      data.setUint32(0x1010, 0x11111111, Endian.little);
      data.setUint32(0x2010, 0x22222222, Endian.little);
      final reads = rt.addTranslationTable(write: false, keyed: true);
      const user = 0x801, system = 0xc01;
      rt.mapTranslation(reads, 0x00010000, user, 0x0c001000);
      rt.mapTranslation(reads, 0x00010000, system, 0x0c002000);
      expect(rt.translate(reads, user, 0x00010010), 0x0c001010);
      expect(rt.translate(reads, system, 0x00010010), 0x0c002010);

      // ctx[16] is loaded through the translation under each key.
      for (final (pc, key) in [(0x100, user), (0x200, system)]) {
        final b = IrBuilder(pc);
        final exit = IrExit(JitReason.user + 1, pc, spent: 0);
        b.ctxStore(
          18,
          b.load(
            4,
            b.ctxLoad(16),
            unmapped: exit,
            translation: IrTranslation(reads, key),
          ),
        );
        rt.install(
          b.finish(IrExitTerm(IrExit(JitReason.user, pc + 4)), cost: 1),
        );
      }

      int run(int pc) {
        rt.ctx
          ..[16] = 0x00010010
          ..[18] = 0
          ..[JitCtx.budget] = 100;
        return rt.run(pc, 0);
      }

      expect(run(0x100), JitReason.user);
      expect(rt.ctx[18], 0x11111111);
      expect(run(0x200), JitReason.user);
      expect(rt.ctx[18], 0x22222222);

      // Unmapping the virtual page empties its slot under both keys.
      rt.unmapTranslation(reads, 0x00010000);
      expect(rt.translate(reads, user, 0x00010010), isNull);
      expect(rt.translate(reads, system, 0x00010010), isNull);
      expect(run(0x100), JitReason.user + 1);
      expect(run(0x200), JitReason.user + 1);
    });

    test('$name translations require an exit and a registered table', () {
      final rt = create([]);
      if (rt == null) {
        markTestSkipped('no compiled runtime on this host');
        return;
      }
      addTearDown(rt.dispose);
      final table = rt.addTranslationTable(write: false);
      final b = IrBuilder(0x100);
      b.ctxStore(
        16,
        b.load(4, b.ctxLoad(16), translation: IrTranslation(table, 1)),
      );
      expect(
        () => rt.install(
          b.finish(const IrExitTerm(IrExit(JitReason.user, 0x104)), cost: 1),
        ),
        throwsA(anything),
      );
      final c = IrBuilder(0x100);
      c.ctxStore(
        16,
        c.load(
          4,
          c.ctxLoad(16),
          unmapped: const IrExit(JitReason.user, 0x100),
          translation: IrTranslation(table + 1, 1),
        ),
      );
      expect(
        () => rt.install(
          c.finish(const IrExitTerm(IrExit(JitReason.user, 0x104)), cost: 1),
        ),
        throwsA(anything),
      );
      expect(() => rt.mapTranslation(table, 0, 0, 0), throwsArgumentError);
    });
  }
}
