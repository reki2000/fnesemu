import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

/// Minimal, self-checking labs for TUTORIAL_JA.md.
/// Run: dart run tool/jit_learning_lab.dart [--native]
void main(List<String> args) {
  final nativeRequested = args.contains('--native');
  final JitRuntime rt =
      (nativeRequested
          ? JitRuntime.native(
              ctxWords: 64,
              addrMask: 0xffff,
              read: (address, size) => 0,
              write: (address, size, value) {},
            )
          : null) ??
      JitRuntime.interpreter(
        ctxWords: 64,
        addrMask: 0xffff,
        read: (address, size) => 0,
        write: (address, size, value) {},
      );

  try {
    print('backend: ${nativeRequested && JitRuntime.nativeSupported ? 'compiled' : 'reference IR'}');
    arithmeticLab(rt);
    chainingLab(rt);
    memoryLab(rt);
    unmappedExitLab(rt);
    wideAndHelperLab(rt);
    codeGuardLab(rt);
    print('All JIT learning labs passed.');
  } finally {
    rt.dispose();
  }
}

void check(Object? actual, Object? expected, String label) {
  if (actual != expected) {
    throw StateError('$label: expected $expected, got $actual');
  }
}

void reset(JitRuntime rt, {int budget = 10}) {
  rt.clear();
  rt.ctx.fillRange(JitCtx.user, rt.ctx.length, 0);
  rt.ctx[JitCtx.budget] = budget;
  rt.ctx[JitCtx.stop] = 0;
  rt.ctx[JitCtx.faultAddr] = 0;
}

void arithmeticLab(JitRuntime rt) {
  reset(rt);
  final b = IrBuilder(0x100);
  final x = b.ctxLoad(JitCtx.user);
  b.ctxStore(JitCtx.user, b.add(x, b.c32(5)));
  rt.install(b.finish(
    const IrExitTerm(IrExit(JitReason.user, 0x104)),
    cost: 3,
  ));

  rt.ctx[JitCtx.user] = 7;
  final reason = rt.run(0x100, 0);
  check(reason, JitReason.user, 'arithmetic reason');
  check(rt.ctx[JitCtx.user], 12, 'arithmetic result');
  check(rt.ctx[JitCtx.budget], 7, 'arithmetic budget');
  check(rt.exitPc, 0x104, 'arithmetic exit PC');
  print('A arithmetic: r0=12, budget=7');
}

void chainingLab(JitRuntime rt) {
  reset(rt);
  final first = IrBuilder(0x300);
  first.ctxStore(
    JitCtx.user,
    first.add(first.ctxLoad(JitCtx.user), first.c32(1)),
  );
  rt.install(first.finish(const IrJump(0x304), cost: 2));

  final second = IrBuilder(0x304);
  second.ctxStore(
    JitCtx.user,
    second.add(second.ctxLoad(JitCtx.user), second.c32(1)),
  );
  rt.install(second.finish(
    const IrExitTerm(IrExit(JitReason.user, 0x308)),
    cost: 4,
  ));
  final reason = rt.run(0x300, 0);
  check(reason, JitReason.user, 'chaining reason');
  check(rt.ctx[JitCtx.user], 2, 'chaining register');
  check(rt.ctx[JitCtx.budget], 4, 'chaining budget');
  print('B chaining: r0=2, budget=4');
}

void memoryLab(JitRuntime rt) {
  reset(rt);
  final ram = rt.alloc(4096);
  rt.mapPages(0x1000, 4096, ram);
  ram.setRange(0, 4, [0x12, 0x34, 0x56, 0x78]);

  final b = IrBuilder(0x400);
  b.ctxStore(
    JitCtx.user,
    b.load(4, b.c32(0x1000), endian: IrEndian.big),
  );
  b.store(
    4,
    b.c32(0x1004),
    b.c32(0x11223344),
    endian: IrEndian.big,
  );
  rt.install(b.finish(
    const IrExitTerm(IrExit(JitReason.user, 0x404)),
    cost: 5,
  ));

  check(rt.run(0x400, 0), JitReason.user, 'memory reason');
  check(rt.ctx[JitCtx.user], 0x12345678, 'big endian load');
  check(ram[4], 0x11, 'big endian byte 0');
  check(ram[5], 0x22, 'big endian byte 1');
  check(ram[6], 0x33, 'big endian byte 2');
  check(ram[7], 0x44, 'big endian byte 3');
  print('C memory: read=0x12345678, write=[11,22,33,44]');
}

void unmappedExitLab(JitRuntime rt) {
  reset(rt);
  final b = IrBuilder(0x500);
  final address = b.c32(0x3000);
  b.ctxStore(
    JitCtx.user,
    b.load(
      4,
      address,
      unmapped: const IrExit(JitReason.user + 1, 0x504, spent: 0),
    ),
  );
  rt.install(b.finish(
    const IrExitTerm(IrExit(JitReason.user + 2, 0x508)),
    cost: 6,
  ));

  final reason = rt.run(0x500, 0);
  check(reason, JitReason.user + 1, 'unmapped reason');
  check(rt.ctx[JitCtx.faultAddr], 0x3000, 'fault address');
  check(rt.ctx[JitCtx.budget], 10, 'side exit refund');
  check(rt.ctx[JitCtx.user], 0, 'no effects before exit');
  print('D unmapped: fault=0x3000, spent=0');
}

void wideAndHelperLab(JitRuntime rt) {
  reset(rt);
  final helper = rt.addHelper((a, b, c) => a + b + c);
  final b = IrBuilder(0x600);
  b.ctxStore(
    JitCtx.user,
    b.call(helper, b.c32(3), b.c32(4), b.c32(5)),
  );
  final wide = b.add(
    b.c64(BigInt.parse('18446744073709551615')),
    b.c64(BigInt.from(2)),
  );
  b.ctxStore(JitCtx.user + 2, wide);
  rt.install(b.finish(
    const IrExitTerm(IrExit(JitReason.user, 0x604)),
    cost: 2,
  ));

  check(rt.run(0x600, 0), JitReason.user, 'wide/helper reason');
  check(rt.ctx[JitCtx.user], 12, 'helper return');
  check(rt.ctx[JitCtx.user + 2], 1, 'i64 low word');
  check(rt.ctx[JitCtx.user + 3], 0, 'i64 high word');
  print('E helper/i64: helper=12, wrapped i64=1');
}

void codeGuardLab(JitRuntime rt) {
  reset(rt);
  // Reuse the mapped page from memoryLab. Little-endian word is 0x78563412.
  final page = rt.readPages[0x1000 >>> rt.pageShift];
  if (page == null) throw StateError('the memory lab must run first');
  final (ram, offset) = page;
  ram.setRange(offset, offset + 4, [0x12, 0x34, 0x56, 0x78]);

  final b = IrBuilder(0x700);
  b.guard(0x1000, 0x78563412);
  b.ctxStore(JitCtx.user, b.c32(42));
  rt.install(b.finish(
    const IrExitTerm(IrExit(JitReason.user, 0x704)),
    cost: 1,
  ));

  check(rt.run(0x700, 0), JitReason.user, 'guard success');
  check(rt.ctx[JitCtx.user], 42, 'guarded instruction result');

  ram[offset] = 0x13; // Change a guarded code word without recompiling.
  rt.ctx[JitCtx.budget] = 10;
  rt.ctx[JitCtx.user] = 0;
  check(rt.run(0x700, 0), JitReason.invalid, 'guard invalidation');
  check(rt.ctx[JitCtx.user], 0, 'guard must prevent execution');
  print('F code guard: changed word -> invalid');
}
