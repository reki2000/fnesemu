import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

void main() {
  late JitRuntime rt;
  late Map<int, int> code;
  late List<int> translated;
  late List<int> guarded;
  setUp(() {
    rt = JitRuntime.interpreter(
      ctxWords: 32,
      addrMask: 0xffff,
      read: (_, __) => 0,
      write: (_, __, ___) {},
    );
    code = {0x100: 1, 0x200: 2};
    translated = [];
    guarded = List.filled(0x400, 0);
  });
  tearDown(() => rt.dispose());

  // 0x100 jumps to 0x200, which exits; a code word of 0 does not translate.
  IrBlock? translate(int pc, int tag) {
    translated.add(pc);
    if (code[pc] == 0) return null;
    final b = IrBuilder(pc, tag: tag);
    // The guard expects the word seen now, as a real translator reads it.
    if (code[pc] != null) b.guard(0x1000 + pc, guarded[pc]);
    return b.finish(
      pc == 0x100
          ? const IrJump(0x200)
          : IrExitTerm(IrExit(JitReason.user, pc + 4)),
      cost: 1,
    );
  }

  JitDriver driver({bool recompileInvalid = false, int capacity = 1 << 16}) =>
      JitDriver(
        rt,
        translate: translate,
        codeWord: (pc) => code[pc],
        threshold: 3,
        capacity: capacity,
        recompileInvalid: recompileInvalid,
      );

  int run(JitDriver d, int pc) {
    rt.ctx[JitCtx.budget] = 100;
    return d.run(pc, 0);
  }

  test('blocks translate after the threshold and successors chain', () {
    final d = driver();
    expect(run(d, 0x100), JitReason.miss);
    expect(run(d, 0x100), JitReason.miss);
    expect(translated, isEmpty);
    // The third miss translates 0x100; its successor 0x200 is still cold.
    expect(run(d, 0x100), JitReason.miss);
    expect(translated, [0x100]);
    expect(rt.exitPc, 0x200);
    run(d, 0x100);
    expect(run(d, 0x100), JitReason.user);
    expect(translated, [0x100, 0x200]);
  });

  test('fallbacks hold until the code word changes', () {
    final d = driver();
    code[0x100] = 0;
    for (var i = 0; i < 3; i++) {
      run(d, 0x100);
    }
    expect(d.isFallback(0x100, 0), isTrue);
    expect(translated, [0x100]);
    run(d, 0x100);
    expect(translated, [0x100]);
    code[0x100] = 5;
    expect(d.isFallback(0x100, 0), isFalse);
    for (var i = 0; i < 3; i++) {
      run(d, 0x100);
    }
    expect(translated, [0x100, 0x100]);
  });

  test('pcs without code words never translate', () {
    final d = driver();
    for (var i = 0; i < 5; i++) {
      expect(run(d, 0x300), JitReason.miss);
    }
    expect(translated, isEmpty);
  });

  for (final recompile in [false, true]) {
    test(
      'a failed guard ${recompile ? 'translates again at once' : 'counts as a miss'}',
      () {
        final d = driver(recompileInvalid: recompile);
        final ram = rt.alloc(0x1000);
        rt.mapPages(0x1000, ram.length, ram);
        for (var i = 0; i < 3; i++) {
          run(d, 0x200);
        }
        expect(translated, [0x200]);
        ram[0x200] = 1; // the guard of 0x200 reads a changed word
        guarded[0x200] = 1;
        final reason = run(d, 0x200);
        expect(translated.length, recompile ? 2 : 1);
        expect(reason, recompile ? JitReason.user : JitReason.invalid);
        expect(rt.contains(0x200, 0), recompile);
      },
    );
  }

  test('counters and fallbacks clear at the capacity', () {
    final d = driver(capacity: 2);
    code[0x300] = 0;
    for (var i = 0; i < 3; i++) {
      run(d, 0x300);
    }
    expect(d.isFallback(0x300, 0), isTrue);
    run(d, 0x100);
    run(d, 0x200);
    expect(d.isFallback(0x300, 0), isFalse);
  });

  test('prepared entries observe live state without cold runtime entries', () {
    final observations = <(int, int)>[];
    final exits = <int>[];
    final d =
        JitDriver(
            rt,
            codeWord: (pc) => code[pc],
            threshold: 2,
            prepareFirst: true,
            translate: (pc, tag) {
              final b = IrBuilder(pc, tag: tag);
              b.ctxStore(8, b.add(b.ctxLoad(8), b.c32(1)));
              return b.finish(
                pc == 0x100
                    ? const IrJump(0x200)
                    : IrExitTerm(IrExit(JitReason.user, pc + 4)),
                cost: 1,
              );
            },
          )
          ..onObserve = (pc, _) {
            observations.add((pc, rt.ctx[8]));
          }
          ..onExit = (reason, _) => exits.add(reason);
    rt.ctx[8] = 11;
    expect(run(d, 0x100), JitReason.miss);
    expect(exits, isEmpty);
    expect(rt.exitPc, 0x100);
    rt.ctx[8] = 22;
    expect(run(d, 0x100), JitReason.miss);
    expect(rt.exitPc, 0x200);
    rt.ctx[8] = 33;
    expect(run(d, 0x200), JitReason.user);
    expect(observations, [(0x100, 11), (0x100, 22), (0x200, 23), (0x200, 33)]);
    expect(exits, [JitReason.miss, JitReason.user]);
  });

  test('prepared guard retries stop at the host dispatch limit', () {
    final ram = rt.alloc(0x1000);
    rt.mapPages(0x1000, ram.length, ram);
    var attempts = 0, invalidations = 0;
    final d = JitDriver(
      rt,
      codeWord: (_) => 1,
      threshold: 1,
      prepareFirst: true,
      maxDispatches: 3,
      translate: (pc, tag) {
        attempts++;
        final b = IrBuilder(pc, tag: tag)..guard(0x1000, 1);
        return b.finish(IrExitTerm(IrExit(JitReason.user, pc)), cost: 1);
      },
    )..onInvalidate = (_, __) => invalidations++;
    expect(run(d, 0x100), JitReason.invalid);
    expect(attempts, 3);
    expect(invalidations, 3);
    expect(rt.ctx[JitCtx.budget], 100);
    expect(rt.contains(0x100, 0), isFalse);
  });

  test('adapter return policy stops before observing a successor', () {
    final observations = <int>[];
    final d = JitDriver(
      rt,
      codeWord: (pc) => code[pc],
      threshold: 1,
      prepareFirst: true,
      continueAfterExit: (_) => false,
      translate: translate,
    )..onObserve = (pc, _) => observations.add(pc);
    expect(run(d, 0x100), JitReason.miss);
    expect(rt.exitPc, 0x200);
    expect(observations, [0x100]);
    expect(rt.contains(0x200, 0), isFalse);
  });

  test('explicit warm invalidation recompiles without another warmup', () {
    final d = driver();
    for (var i = 0; i < 3; i++) {
      run(d, 0x200);
    }
    d.invalidate(0x200, 0, warm: true);
    expect(run(d, 0x200), JitReason.user);
    expect(translated, [0x200, 0x200]);
  });

  test('budgeted batches count signed overshoot and reset a stale stop', () {
    final d = JitDriver(
      rt,
      threshold: 1,
      codeWord: (_) => 1,
      translate: (pc, tag) => IrBuilder(
        pc,
        tag: tag,
      ).finish(IrExitTerm(IrExit(JitReason.user, pc + 4)), cost: 5),
    );
    rt.ctx[JitCtx.stop] = 1;
    final first = d.runBudgeted(0x100, 0, 2);
    expect(first, JitReason.user);
    expect(d.lastClocks, 5);
    expect(rt.ctx[JitCtx.budget].toSigned(32), -3);
    expect(d.executedClocks, 5);
    final second = d.runBudgeted(0x100, 0, 7);
    expect(second, JitReason.user);
    expect(d.lastClocks, 5);
    expect(d.executedClocks, 10);
    // Dispatch-cache maintenance must not erase lifetime batch accounting.
    d.clear();
    expect(d.executedClocks, 10);
  });

  test('cold prepared entries consume no clocks or stale runtime budget', () {
    final d = JitDriver(
      rt,
      threshold: 2,
      prepareFirst: true,
      translate: translate,
      codeWord: (pc) => code[pc],
    );
    rt.ctx[JitCtx.budget] = 0xffffffff;
    expect(d.runBudgeted(0x200, 0, 10), JitReason.miss);
    expect(d.lastClocks, 0);
    expect(d.executedClocks, 0);
    d.runBudgeted(0x200, 0, 10);
    expect(d.lastClocks, 1);
    expect(d.executedClocks, 1);
  });

  test(
    'reset restores aliases, clears batches and profiles, retains wiring',
    () {
      final ram = rt.alloc(0x1000);
      final memory = JitCodeMemory(rt)
        ..map(0x1000, ram.length, ram)
        ..map(0x2000, ram.length, ram);
      var clears = 0;
      final helper = rt.addHelper((a, b, c) => a + b + c);
      final d = JitDriver(
        rt,
        codeMemory: memory,
        threshold: 1,
        codeWord: (_) => 1,
        translate: (pc, tag) {
          memory.protect(0x1000, block: (pc, tag));
          final b = IrBuilder(pc, tag: tag);
          b.ctxStore(21, b.call(helper, b.c32(1), b.c32(2), b.c32(3)));
          return b.finish(IrExitTerm(IrExit(JitReason.user, pc)), cost: 2);
        },
      )..onClear = () => clears++;
      ram[12] = 42;
      rt.ctx[20] = 81;
      d.runBudgeted(0x100, 0, 3);
      expect(d.lastClocks, 2);
      expect(rt.writePages[1], isNull);
      expect(rt.writePages[2], isNull);
      d.reset();
      expect(rt.contains(0x100, 0), isFalse);
      expect(rt.writePages[1]!.$1, same(ram));
      expect(rt.writePages[2]!.$1, same(ram));
      expect(ram[12], 42);
      expect(rt.ctx[20], 81);
      expect(d.executedClocks, 0);
      expect(clears, 1);
      rt.ctx[21] = 0;
      d.runBudgeted(0x100, 0, 3);
      expect(rt.ctx[21], 6);
    },
  );

  test('a miss on an installed block runs it instead of translating again', () {
    final native = JitRuntime.native(
      ctxWords: 32,
      addrMask: 0xffff,
      read: (_, __) => 0,
      write: (_, __, ___) {},
    );
    if (native == null) return;
    addTearDown(native.dispose);
    // The two blocks jump to each other through the dynamic table and share
    // one of its entries, so the native code misses on every transfer.
    const a = 0x1000, b = 0x5000;
    final seen = <int>[];
    IrBlock translateLoop(int pc, int tag) {
      seen.add(pc);
      final bld = IrBuilder(pc, tag: tag);
      return bld.finish(IrJumpDyn(bld.c32(pc == a ? b : a)), cost: 1);
    }

    final d = JitDriver(
      native,
      translate: translateLoop,
      codeWord: (pc) => 1,
      threshold: 1,
      capacity: 1 << 16,
    );
    native.ctx[JitCtx.budget] = 1000;
    expect(d.run(a, 0), JitReason.budget);
    expect(seen, [a, b]);
    expect(native.contains(a, 0), isTrue);
  });
}
