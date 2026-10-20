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
              signed: rnd.nextBool());
        }(),
      23 => () {
          final size = 1 << rnd.nextInt(3);
          b.store(size, b.and(addr(), b.c32(~(size - 1))), x);
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
      for (final env in [a, b]) {
        env.rt.clear();
        env.rt.install(block);
        env.log.clear();
        env.ctx.setAll(8, init.sublist(8));
        env.rt.ctx[JitCtx.budget] = 100;
        env.rt.ctx[JitCtx.stop] = 0;
        expect(env.rt.run(0x200, 0), JitReason.miss);
      }
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
        expect(env.ctx[JitCtx.budget], 10000 - 2000 - 2);

        // a dynamic jump to a missing block
        env.ctx[8] = 0;
        env.ctx[9] = 1;
        env.ctx[10] = 0x404;
        run(0x100);
        expect(env.ctx[JitCtx.exitReason], JitReason.miss);
        expect(rt.exitPc, 0x404);
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
