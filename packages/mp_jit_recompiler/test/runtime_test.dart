import 'dart:math';
import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

const _ctxWords = 64;
const _addrMask = 0x1fffffff;

/// A runtime with one mapped RAM page at 0x1000 (mirrored at 0x81000), a
/// read-only page at 0x2000 and logged accesses everywhere else.
final class _Env {
  final JitRuntime rt;
  final log = <String>[];
  late final Uint8List ram, rom;

  _Env(JitRuntime Function(JitRead, JitWrite) create)
      : rt = create((a, s) => 0, (a, s, v) {}) {
    ram = rt.alloc(4096);
    rom = rt.alloc(4096);
    rt.mapPages(0x1000, 4096, ram);
    rt.mapPages(0x81000, 4096, ram);
    rt.mapPages(0x2000, 4096, rom, write: false);
    for (int i = 0; i < 4096; i++) {
      rom[i] = i * 7;
    }
  }

  void dispose() => rt.dispose();
}

typedef _Factory = JitRuntime Function(JitRead, JitWrite);

final _factories = <String, _Factory?>{
  'interpreter': (r, w) => JitRuntime.interpreter(
      ctxWords: _ctxWords, addrMask: _addrMask, read: r, write: w),
  'native': JitRuntime.nativeSupported
      ? (r, w) => JitRuntime.native(
          ctxWords: _ctxWords, addrMask: _addrMask, read: r, write: w)!
      : null,
};

/// The logging read and write functions need the env, so they forward to
/// late-bound closures.
_Env _env(_Factory f) {
  late _Env env;
  int read(int a, int s) {
    env.log.add('r ${a.toRadixString(16)} $s');
    return (a * 0x9e3779b1).toUnsigned(32);
  }

  void write(int a, int s, int v) =>
      env.log.add('w ${a.toRadixString(16)} $s ${v.toRadixString(16)}');

  env = _Env((r, w) => f(read, write));
  return env;
}

/// A random block over the context words 8..23, the mapped pages and the
/// unmapped area, ending with a jump to (0x100, 0).
IrBlock _randomBlock(Random rnd, int helper) {
  final b = IrBuilder(0x200);
  final values = <IrValue>[for (int i = 0; i < 4; i++) b.ctxLoad(8 + i)];
  IrValue pick() => values[rnd.nextInt(values.length)];
  IrValue addr() {
    final base = [0x1000, 0x81000, 0x2000, 0x5000, 0xa0001000][rnd.nextInt(5)];
    final size = [1, 2, 4][rnd.nextInt(3)];
    return b.c32(base + (rnd.nextInt(4096) & ~(size - 1)));
  }

  final constants = [0, 1, 2, 31, 32, 0x7fffffff, 0x80000000, -1, 0x1234];
  // some accesses leave the block at an unmapped page
  IrExit? unmapped() => rnd.nextInt(4) == 0
      ? IrExit(JitReason.user + rnd.nextInt(4), 0x300 + rnd.nextInt(16) * 4,
          tag: rnd.nextInt(8), spent: rnd.nextInt(11))
      : null;
  for (int i = 0; i < 40; i++) {
    final x = pick(), y = pick();
    final IrValue v = switch (rnd.nextInt(26)) {
      0 => b.c32(constants[rnd.nextInt(constants.length)]),
      1 => b.c32(rnd.nextInt(0x100000000)),
      2 => b.add(x, y),
      3 => b.sub(x, y),
      4 => b.mul(x, y),
      5 => b.mulHiS(x, y),
      6 => b.mulHiU(x, y),
      7 => b.and(x, y),
      8 => b.or(x, y),
      9 => b.xor(x, y),
      10 => b.shl(x, y),
      11 => b.shrU(x, y),
      12 => b.shrS(x, y),
      13 => b.eq(x, y),
      14 => b.ne(x, y),
      15 => b.ltS(x, y),
      16 => b.ltU(x, y),
      17 => b.select(pick(), x, y),
      18 => b.sext8(x),
      19 => b.sext16(x),
      20 => b.zext8(x),
      21 => b.zext16(x),
      22 => () {
          final a = addr();
          return b.load(1 << rnd.nextInt(3), b.and(a, b.c32(~3)),
              signed: rnd.nextBool(), unmapped: unmapped());
        }(),
      23 => () {
          final size = 1 << rnd.nextInt(3);
          b.store(size, b.and(addr(), b.c32(~(size - 1))), x,
              unmapped: unmapped());
          return x;
        }(),
      24 => b.call(helper, x, y, pick()),
      _ => () {
          b.ctxStore(8 + rnd.nextInt(16), x);
          return x;
        }(),
    };
    values.add(v);
  }
  for (int i = 0; i < 16; i++) {
    b.ctxStore(8 + i, pick());
  }
  return b.finish(const IrJump(0x100), cost: 10);
}

void main() {
  test('native block profiling accounts for chained partial and refunded entries', () {
    if (!JitRuntime.nativeSupported) {
      markTestSkipped('No native runtime');
      return;
    }
    final rt = JitRuntime.native(ctxWords: 32, addrMask: 0xffff,
        read: (_, __) => 0, write: (_, __, ___) {})!;
    addTearDown(rt.dispose);
    rt.enableBlockProfiling();
    final a = IrBuilder(0x100);
    a.ctxStore(8, a.c32(42));
    rt.install(a.finish(const IrJump(0x200), cost: 4));
    final b = IrBuilder(0x200);
    b.exitIf(b.c32(1), const IrExit(JitReason.user, 0x204, spent: 3));
    rt.install(b.finish(const IrJump(0x300), cost: 10));
    final c = IrBuilder(0x300);
    c.exitIf(c.c32(1), const IrExit(JitReason.user, 0x300, spent: 0));
    rt.install(c.finish(const IrJump(0x100), cost: 8));
    rt.ctx[JitCtx.budget] = 20;
    expect(rt.run(0x100, 0), JitReason.user);
    expect(rt.ctx[JitCtx.budget], 13);
    expect(rt.executedBlockCycles, {4: 1, 3: 1});
    rt.ctx[JitCtx.budget] = 20;
    expect(rt.run(0x300, 0), JitReason.user);
    expect(rt.ctx[JitCtx.budget], 20);
    expect(rt.executedBlockCycles, {4: 1, 3: 1});
    expect(rt.ctx[8], 42);
  });

  test('random blocks behave the same on every runtime', () {
    final native = _factories['native'];
    if (native == null) {
      markTestSkipped('no native runtime on this host');
      return;
    }
    final a = _env(_factories['interpreter']!), b = _env(native);
    for (final env in [a, b]) {
      final log = env.log;
      env.rt.addHelper((x, y, z) {
        log.add('h $x $y $z');
        return (x * 31 + y * 7 + z).toUnsigned(32);
      });
    }
    final rnd = Random(1);
    for (int n = 0; n < 2000; n++) {
      final block = _randomBlock(rnd, 0);
      final init = [for (int i = 0; i < 24; i++) rnd.nextInt(0x100000000)];
      final reasons = <int>[];
      for (final env in [a, b]) {
        env.rt.clear();
        env.rt.install(block);
        env.log.clear();
        env.ctx.setAll(8, init.sublist(8));
        env.rt.ctx[JitCtx.budget] = 100;
        env.rt.ctx[JitCtx.stop] = 0;
        env.rt.ctx[JitCtx.faultAddr] = 0;
        reasons.add(env.rt.run(0x200, 0));
      }
      expect(reasons[1], reasons[0], reason: '$block');
      expect(b.rt.ctx, a.rt.ctx, reason: '$block');
      expect(b.ram, a.ram, reason: '$block');
      expect(b.log, a.log, reason: '$block');
    }
    a.dispose();
    b.dispose();
  });

  for (final MapEntry(key: name, value: factory) in _factories.entries) {
    group(name, () {
      late _Env env;
      setUp(() {
        if (factory == null) {
          markTestSkipped('no native runtime on this host');
          return;
        }
        env = _env(factory);
      });
      tearDown(() {
        if (factory != null) env.dispose();
      });

      void run(int pc, {int budget = 1000}) {
        env.ctx[JitCtx.budget] = budget;
        env.ctx[JitCtx.stop] = 0;
        env.rt.run(pc, 0);
      }

      test('two runtimes share guest RAM while keeping separate contexts', () {
        if (factory == null) return;
        final peer = _env(factory);
        addTearDown(peer.dispose);
        peer.rt.shareBuffer(env.rt, env.ram);
        peer.rt.mapPages(0x3000, 4096, env.ram);
        final writer = IrBuilder(0x100);
        writer.store(4, writer.c32(0x3000), writer.c32(0x89abcdef));
        writer.ctxStore(8, writer.c32(17));
        peer.rt.install(
          writer.finish(
            const IrExitTerm(IrExit(JitReason.user, 0x104)),
            cost: 1,
          ),
        );
        peer.ctx[JitCtx.budget] = 1;
        expect(peer.rt.run(0x100, 0), JitReason.user);
        final reader = IrBuilder(0x100);
        reader.ctxStore(8, reader.load(4, reader.c32(0x1000)));
        env.rt.install(
          reader.finish(
            const IrExitTerm(IrExit(JitReason.user, 0x104)),
            cost: 1,
          ),
        );
        run(0x100);
        expect(env.ctx[8], 0x89abcdef);
        expect(peer.ctx[8], 17);
      });

      test('blocks chain through static, branch and dynamic exits', () {
        if (factory == null) return;
        final rt = env.rt;
        // 0x100: r8 += 1; branch r8 < r9 ? 0x100 : 0x200
        final b1 = IrBuilder(0x100);
        final r8 = b1.add(b1.ctxLoad(8), b1.c32(1));
        b1.ctxStore(8, r8);
        rt.install(b1.finish(IrBranch(b1.ltU(r8, b1.ctxLoad(9)), 0x100, 0x200),
            cost: 2));
        // 0x200: jump to ctx[10]
        final b2 = IrBuilder(0x200);
        rt.install(b2.finish(IrJumpDyn(b2.ctxLoad(10)), cost: 1));
        // 0x300: exit 99
        final b3 = IrBuilder(0x300);
        rt.install(b3.finish(
            const IrExitTerm(IrExit(JitReason.user + 1, 0x300, tag: 5)),
            cost: 1));

        env.ctx[9] = 1000;
        env.ctx[10] = 0x300;
        run(0x100, budget: 10000);
        expect(env.ctx[JitCtx.exitReason], JitReason.user + 1);
        expect(rt.exitPc, 0x300);
        expect(rt.exitTag, 5);
        expect(env.ctx[8], 1000);
        if (name == 'native') {
          expect(rt.nativeEntries, 1);
        }
        expect(env.ctx[JitCtx.budget], 10000 - 2000 - 2);

        // a dynamic jump to a missing block
        env.ctx[8] = 0;
        env.ctx[9] = 1;
        env.ctx[10] = 0x404;
        run(0x100);
        expect(env.ctx[JitCtx.exitReason], JitReason.miss);
        expect(rt.exitPc, 0x404);
        if (name == 'native') {
          expect(rt.nativeEntries, 2);
          run(0x404);
          expect(rt.nativeEntries, 2);
        }
      });

      test('dynamic misses refresh installed targets after collisions', () {
        if (factory == null) return;
        final rt = env.rt;
        for (final pc in [0x300, 0x302]) {
          final b = IrBuilder(pc, tag: 7);
          b.ctxStore(8, b.c32(pc));
          rt.install(
            b.finish(const IrExitTerm(IrExit(JitReason.user, 0x400)), cost: 1),
          );
        }
        final jump = IrBuilder(0x100);
        rt.install(jump.finish(IrJumpDyn(jump.ctxLoad(10), tag: 7), cost: 1));
        for (final pc in [0x300, 0x302, 0x300]) {
          env.ctx[10] = pc;
          if (name == 'native') {
            run(0x100);
            expect(env.ctx[JitCtx.exitReason], JitReason.miss);
            expect(rt.exitPc, pc);
          }
          run(0x100);
          expect(env.ctx[JitCtx.exitReason], JitReason.user);
          expect(env.ctx[8], pc);
        }
        env.ctx[10] = 0x302;
        if (name == 'native') run(0x100);
        run(0x100);
        rt.invalidate(0x300, 7);
        run(0x100);
        expect(env.ctx[JitCtx.exitReason], JitReason.user);
        expect(env.ctx[8], 0x302);
        env.ctx[10] = 0x300;
        run(0x100);
        expect(env.ctx[JitCtx.exitReason], JitReason.miss);
        run(0x100);
        expect(env.ctx[JitCtx.exitReason], JitReason.miss);
      });

      test('the budget and the stop word end a run at a block entry', () {
        if (factory == null) return;
        final b1 = IrBuilder(0x100);
        b1.ctxStore(8, b1.add(b1.ctxLoad(8), b1.c32(1)));
        env.rt.install(b1.finish(const IrJump(0x100), cost: 3));
        run(0x100, budget: 10);
        expect(env.ctx[JitCtx.exitReason], JitReason.budget);
        expect(env.ctx[8], 4);
        expect(env.ctx[JitCtx.budget].toSigned(32), -2);

        env.ctx[JitCtx.budget] = 10;
        env.ctx[JitCtx.stop] = 1;
        env.rt.run(0x100, 0);
        expect(env.ctx[JitCtx.exitReason], JitReason.budget);
        expect(env.ctx[8], 4);
        if (name == 'native') {
          expect(env.rt.nativeEntries, 2);
        }
      });

      test('return profiling covers linked work, zero work and memory faults', () {
        if (factory == null || name != 'native') {
          return;
        }
        final rt = env.rt;
        rt.enableBlockProfiling();
        final exits = <(int, int, int, int, int, int, int?)>[];
        rt.onNativeExit = (entry, exit, reason, budget, cycles, stop, fault) {
          exits.add((entry, exit, reason, budget, cycles, stop, fault));
        };
        final loop = IrBuilder(0x100);
        loop.ctxStore(8, loop.add(loop.ctxLoad(8), loop.c32(1)));
        rt.install(loop.finish(const IrJump(0x100), cost: 3));
        run(0x100, budget: 10);
        expect(exits.single, (0x100, 0x100, JitReason.budget, 10, 12, 0, null));
        expect(env.ctx[8], 4);
        run(0x100, budget: 0);
        expect(exits.last, (0x100, 0x100, JitReason.budget, 0, 0, 0, null));
        final fault = IrBuilder(0x200);
        fault.store(4, fault.c32(0x6000), fault.c32(7),
            unmapped: const IrExit(JitReason.user, 0x204, spent: 0));
        rt.install(fault.finish(const IrJump(0x208), cost: 1));
        run(0x200, budget: 9);
        expect(exits.last, (0x200, 0x204, JitReason.user, 9, 0, 0, 0x6000));
        run(0x404);
        expect(exits.length, 3);
        expect(rt.nativeEntries, 3);
      });

      test('installed blocks can be replaced, invalidated and cleared', () {
        if (factory == null) return;
        final rt = env.rt;
        expect(rt.contains(0x100, 0), isFalse);
        final b = IrBuilder(0x100);
        rt.install(b.finish(const IrJump(0x200), cost: 7));
        expect(rt.contains(0x100, 0), isTrue);
        run(0x100, budget: 10);
        expect(rt.ctx[JitCtx.budget], 3);
        expect(rt.contains(0x100, 1), isFalse);
        rt.install(b.finish(const IrJump(0x200), cost: 3));
        run(0x100, budget: 10);
        expect(rt.ctx[JitCtx.budget], 7);
        rt.invalidate(0x100, 0);
        expect(rt.contains(0x100, 0), isFalse);
        rt.install(b.finish(const IrJump(0x200), cost: 4));
        rt.clear();
        expect(rt.contains(0x100, 0), isFalse);
      });

      test('a missing link is filled by a later install', () {
        if (factory == null) return;
        final b1 = IrBuilder(0x100);
        env.rt.install(b1.finish(const IrJump(0x200, tag: 3), cost: 1));
        run(0x100);
        expect(env.ctx[JitCtx.exitReason], JitReason.miss);
        expect((env.rt.exitPc, env.rt.exitTag), (0x200, 3));

        final b2 = IrBuilder(0x200, tag: 3);
        b2.ctxStore(8, b2.c32(42));
        env.rt.install(b2
            .finish(const IrExitTerm(IrExit(JitReason.user, 0x204)), cost: 1));
        run(0x100);
        expect(env.ctx[JitCtx.exitReason], JitReason.user);
        expect(env.ctx[8], 42);

        env.rt.invalidate(0x200, 3);
        env.ctx[8] = 0;
        run(0x100);
        expect(env.ctx[JitCtx.exitReason], JitReason.miss);
        expect(env.ctx[8], 0);
      });

      test('register pressure and helper barriers preserve side-exit values',
          () {
        if (factory == null) return;
        final b = IrBuilder(0x100);
        final values = [for (int i = 0; i < 16; i++) b.ctxLoad(16 + i)];
        final before = b.add(values[0], b.c32(7));
        b.exitIf(
            b.ctxLoad(8),
            IrExit(JitReason.user, 0x104,
                spent: 2, stores: [(40, before), (41, values[15])]));
        final helper = env.rt.addHelper((a, b, c) => a + b + c);
        final result = b.call(helper, values[1], values[2], values[3]);
        for (int i = 0; i < 16; i++) {
          b.ctxStore(16 + i, b.xor(values[i], result));
        }
        b.ctxStore(40, before);
        env.rt.install(b.finish(
            const IrExitTerm(IrExit(JitReason.user + 1, 0x108)),
            cost: 6));
        for (final exit in [0, 1]) {
          for (int i = 0; i < 16; i++) {
            env.ctx[16 + i] = i + 100;
          }
          env.ctx[8] = exit;
          run(0x100);
          expect(env.ctx[40], 107);
          if (exit != 0) {
            expect(env.ctx[41], 115);
            expect(env.ctx[JitCtx.budget], 998);
          } else {
            final expected = 101 + 102 + 103;
            expect(env.ctx.sublist(16, 32),
                [for (int i = 0; i < 16; i++) (i + 100) ^ expected]);
            expect(env.ctx[JitCtx.budget], 994);
          }
        }
      });

      test('a side exit refunds the budget', () {
        if (factory == null) return;
        final b = IrBuilder(0x100);
        b.ctxStore(8, b.c32(1));
        b.exitIf(b.ctxLoad(9), const IrExit(JitReason.user, 0x104, spent: 2));
        b.ctxStore(8, b.c32(2));
        env.rt.install(b.finish(
            const IrExitTerm(IrExit(JitReason.user + 1, 0x108)),
            cost: 6));
        env.ctx[9] = 1;
        run(0x100, budget: 100);
        expect(env.ctx[JitCtx.exitReason], JitReason.user);
        expect(env.rt.exitPc, 0x104);
        expect(env.ctx[8], 1);
        expect(env.ctx[JitCtx.budget], 98);
        env.ctx[9] = 0;
        run(0x100, budget: 100);
        expect(env.ctx[JitCtx.exitReason], JitReason.user + 1);
        expect(env.ctx[8], 2);
        expect(env.ctx[JitCtx.budget], 94);
      });

      test('a changed guard word invalidates the block', () {
        if (factory == null) return;
        env.ram[0x10] = 0x78;
        final b = IrBuilder(0x1010);
        b.guard(0x1010, 0x78);
        b.ctxStore(8, b.c32(7));
        env.rt.install(b
            .finish(const IrExitTerm(IrExit(JitReason.user, 0x1014)), cost: 1));
        run(0x1010);
        expect(env.ctx[JitCtx.exitReason], JitReason.user);
        env.ram[0x11] = 1;
        env.ctx[8] = 0;
        run(0x1010);
        expect(env.ctx[JitCtx.exitReason], JitReason.invalid);
        expect(env.ctx[8], 0);
      });

      for (final write in [false, true]) {
        test('unmapped ${write ? 'stores' : 'loads'} exit with the address',
            () {
          if (factory == null) return;
          final b = IrBuilder(0x100);
          final address = b.ctxLoad(9);
          const exit = IrExit(JitReason.user, 0x104, tag: 3, spent: 2);
          if (write) {
            b.store(4, address, b.c32(42), unmapped: exit);
          } else {
            b.ctxStore(10, b.load(4, address, unmapped: exit));
          }
          b.ctxStore(8, b.c32(1));
          env.rt.install(b.finish(
              const IrExitTerm(IrExit(JitReason.user + 1, 0x108)),
              cost: 6));
          for (final address in [0xa0001004, 0x2008, 0x500c]) {
            final allowed = address != 0x500c && (!write || address != 0x2008);
            env.ctx[8] = 0;
            env.ctx[9] = address;
            env.ctx[JitCtx.faultAddr] = 0;
            run(0x100, budget: 100);
            expect(env.ctx[JitCtx.exitReason],
                allowed ? JitReason.user + 1 : JitReason.user);
            expect(env.ctx[8], allowed ? 1 : 0);
            expect(env.ctx[JitCtx.budget], allowed ? 94 : 98);
            expect(env.ctx[JitCtx.faultAddr], allowed ? 0 : address);
            if (!allowed) expect(env.rt.exitTag, 3);
            if (allowed && !write) {
              final word = Uint32List.sublistView(env.rom)[2];
              expect(env.ctx[10], address == 0x2008 ? word : 0);
            }
            expect(env.log, isEmpty);
          }
        });
      }

      for (final write in [false, true]) {
        test('mapped ${write ? 'write' : 'read'} guards exit before callbacks',
            () {
          if (factory == null) return;
          final b = IrBuilder(0x100);
          final address = b.ctxLoad(9);
          b.guardMapped(
              address, const IrExit(JitReason.user, 0x104, tag: 3, spent: 2),
              write: write);
          if (write) {
            b.store(4, address, b.c32(42));
          } else {
            b.ctxStore(10, b.load(4, address));
          }
          b.ctxStore(8, b.c32(1));
          env.rt.install(b.finish(
              const IrExitTerm(IrExit(JitReason.user + 1, 0x108)),
              cost: 6));
          for (final address in [0xa0001000, 0x2000, 0x5000]) {
            final allowed = address != 0x5000 && (!write || address != 0x2000);
            env.ctx[8] = 0;
            env.ctx[9] = address;
            run(0x100, budget: 100);
            expect(env.ctx[JitCtx.exitReason],
                allowed ? JitReason.user + 1 : JitReason.user);
            expect(env.ctx[8], allowed ? 1 : 0);
            expect(env.ctx[JitCtx.budget], allowed ? 94 : 98);
            if (!allowed) expect(env.rt.exitTag, 3);
            expect(env.log, isEmpty);
          }
          env.rt.unmapPages(0x1000, 4096);
          env.ctx[9] = 0x1000;
          run(0x100);
          expect(env.ctx[JitCtx.exitReason], JitReason.user);
          expect(env.log, isEmpty);
        });
      }
    });
  }

  test('a disposed native runtime cannot execute or install code', () {
    final factory = _factories['native'];
    if (factory == null) {
      markTestSkipped('no native runtime on this host');
      return;
    }
    final env = _env(factory);
    final b = IrBuilder(0x100);
    final block =
        b.finish(const IrExitTerm(IrExit(JitReason.user, 0x104)), cost: 1);
    env.rt.install(block);
    env.dispose();
    env.dispose();
    expect(() => env.rt.run(0x100, 0), throwsStateError);
    expect(() => env.rt.install(block), throwsStateError);
  });
}

extension on _Env {
  Uint32List get ctx => rt.ctx;
}
