import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

void main() {
  for (final native in [false, true]) {
    group(
      native ? 'compiled linked exits' : 'reference linked exits',
      () {
        late JitRuntime rt;
        setUp(() {
          rt = native
              ? JitRuntime.native(
                  ctxWords: 32,
                  addrMask: 0xffff,
                  read: (_, __) => 0,
                  write: (_, __, ___) {},
                )!
              : JitRuntime.interpreter(
                  ctxWords: 32,
                  addrMask: 0xffff,
                  read: (_, __) => 0,
                  write: (_, __, ___) {},
                );
        });
        tearDown(() => rt.dispose());

        test(
          'conditional links preserve snapshots, refunds and target entry checks',
          () {
            final ram = rt.alloc(4096);
            rt.mapPages(0x1000, ram.length, ram);
            final words = Uint32List.sublistView(ram);
            words[0] = 0x12345678;
            final b = IrBuilder(0x100);
            final value = b.add(b.ctxLoad(9), b.c32(7));
            b.ctxStore(JitCtx.stop, b.ctxLoad(12));
            b.exitIf(
              b.ctxLoad(8),
              IrExit(
                JitReason.user,
                0x200,
                tag: 3,
                link: true,
                spent: 2,
                stores: [(9, value)],
              ),
            );
            b.ctxStore(9, b.c32(99));
            rt.install(
              b.finish(
                const IrExitTerm(IrExit(JitReason.user, 0x104)),
                cost: 5,
              ),
            );
            final t = IrBuilder(0x200, tag: 3);
            t.guard(0x1000, 0x12345678);
            t.ctxStore(11, t.add(t.ctxLoad(9), t.c32(1)));
            final target = t.finish(
              const IrExitTerm(IrExit(JitReason.user + 1, 0x204, tag: 3)),
              cost: 3,
            );
            int run({int budget = 10, bool take = true, bool stop = false}) {
              rt.ctx[JitCtx.budget] = budget;
              rt.ctx[JitCtx.stop] = 0;
              rt.ctx[8] = take ? 1 : 0;
              rt.ctx[9] = 100;
              rt.ctx[11] = 0;
              rt.ctx[12] = stop ? 1 : 0;
              return rt.run(0x100, 0);
            }

            expect(run(), JitReason.miss);
            expect(
              (rt.exitPc, rt.exitTag, rt.ctx[JitCtx.budget], rt.ctx[9]),
              (0x200, 3, 8, 107),
            );
            rt.install(target);
            expect(run(), JitReason.user + 1);
            expect(
              (
                rt.exitPc,
                rt.exitTag,
                rt.ctx[JitCtx.budget],
                rt.ctx[9],
                rt.ctx[11],
              ),
              (0x204, 3, 5, 107, 108),
            );
            expect(run(take: false), JitReason.user);
            expect(
              (rt.exitPc, rt.ctx[JitCtx.budget], rt.ctx[9], rt.ctx[11]),
              (0x104, 5, 99, 0),
            );
            expect(run(budget: 2), JitReason.budget);
            expect(
              (
                rt.exitPc,
                rt.exitTag,
                rt.ctx[JitCtx.budget],
                rt.ctx[9],
                rt.ctx[11],
              ),
              (0x200, 3, 0, 107, 0),
            );
            expect(run(stop: true), JitReason.budget);
            expect(
              (rt.exitPc, rt.ctx[JitCtx.budget], rt.ctx[11]),
              (0x200, 8, 0),
            );
            words[0] = 0;
            expect(run(), JitReason.invalid);
            expect(
              (rt.exitPc, rt.exitTag, rt.ctx[JitCtx.budget], rt.ctx[11]),
              (0x200, 3, 8, 0),
            );
            words[0] = 0x12345678;
            rt.invalidate(0x200, 3);
            expect(run(), JitReason.miss);
            rt.install(target);
            expect(run(), JitReason.user + 1);
          },
        );

        test(
          'linked terminators preserve wide snapshots and successive refunds',
          () {
            final b = IrBuilder(0x100);
            final x = b.add(b.ctxLoad(16, type: IrType.i64), b.c64Parts(1, 0));
            rt.install(
              b.finish(
                IrExitTerm(
                  IrExit(
                    JitReason.user,
                    0x200,
                    tag: 3,
                    spent: 1,
                    link: true,
                    stores: [(16, x)],
                  ),
                ),
                cost: 3,
              ),
            );
            final t = IrBuilder(0x200, tag: 3);
            t.ctxStore(18, t.ctxLoad(16, type: IrType.i64));
            rt.install(
              t.finish(
                const IrExitTerm(
                  IrExit(JitReason.user, 0x300, tag: 4, spent: 2, link: true),
                ),
                cost: 5,
              ),
            );
            int run() {
              rt.ctx[JitCtx.budget] = 10;
              rt.ctx[16] = 0xffffffff;
              rt.ctx[17] = 0x12345678;
              return rt.run(0x100, 0);
            }

            expect(run(), JitReason.miss);
            expect(
              (rt.exitPc, rt.exitTag, rt.ctx[JitCtx.budget]),
              (0x300, 4, 7),
            );
            expect(rt.ctx.sublist(16, 20), [0, 0x12345679, 0, 0x12345679]);
            final u = IrBuilder(0x300, tag: 4);
            rt.install(
              u.finish(
                const IrExitTerm(IrExit(JitReason.user, 0x304)),
                cost: 2,
              ),
            );
            expect(run(), JitReason.user);
            expect(rt.ctx[JitCtx.budget], 5);
          },
        );
      },
      skip: native && !JitRuntime.nativeSupported
          ? 'Native runtime unavailable'
          : false,
    );
  }
}
